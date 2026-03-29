import Foundation
import Darwin

public actor OpenSSHProcessClient: SSHTransportClientProtocol {
    private var connectedHost: Host?

    public init() {}

    public func connect(to host: Host) async throws {
        connectedHost = host
    }

    public func openShell(pty: PTYSize) async throws -> SSHTransportSessionProtocol {
        guard let host = connectedHost else {
            throw SSHError.notConnected
        }
        return ProcessSSHShellSession(host: host, pty: pty)
    }

    public func disconnect() async {
        connectedHost = nil
    }
}

public typealias SystemSSHClient = OpenSSHProcessClient

public final class ProcessSSHShellSession: SSHTransportSessionProtocol, @unchecked Sendable {
    struct LaunchConfiguration {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
    }

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    private let host: Host
    private let launchConfigurationOverride: LaunchConfiguration?
    private let compatibilityProfileStore: SSHCompatibilityProfileStore
    private var pty: PTYSize
    private var process: Process?
    private var masterHandle: FileHandle?
    private var masterFileDescriptor: Int32?
    private let credentialStore = CredentialStore()
    private let stateQueue = DispatchQueue(label: "io.lighting-tech.remora.ssh.session")
    private let compatibilityRetryWindow: TimeInterval = 3
    private let compatibilityPersistenceDelay: Duration = .seconds(1)
    private let failureProbeBufferLimit = 16 * 1024
    private var activeCompatibilityProfile = SSHCompatibilityProfile()
    private var recentFailureProbeBuffer = Data()
    private var activeAttemptStartedAt: Date?
    private var compatibilityPersistenceTask: Task<Void, Never>?
    private var skipAutoPasswordDelivery = false
    private var cachedStoredPassword: String?
    private var interactivePromptBuffer = ""
    private var interactivePasswordAutofillUsed = false

    public init(host: Host, pty: PTYSize) {
        self.host = host
        self.launchConfigurationOverride = nil
        self.compatibilityProfileStore = .shared
        self.pty = pty
    }

    init(
        host: Host,
        pty: PTYSize,
        launchConfigurationOverride: LaunchConfiguration?,
        compatibilityProfileStore: SSHCompatibilityProfileStore = .shared
    ) {
        self.host = host
        self.launchConfigurationOverride = launchConfigurationOverride
        self.compatibilityProfileStore = compatibilityProfileStore
        self.pty = pty
    }

    public func start() async throws {
        let shouldStart = stateQueue.sync { process == nil }
        guard shouldStart else {
            return
        }

        let initialCompatibilityProfile = await compatibilityProfileStore.cachedProfile(for: host) ?? SSHCompatibilityProfile()
        try await startProcess(using: initialCompatibilityProfile)
    }

    private func startProcess(using compatibilityProfile: SSHCompatibilityProfile) async throws {
        compatibilityPersistenceTask?.cancel()

        let proc = Process()
        let launch = await makeLaunchConfiguration(compatibilityProfile: compatibilityProfile)
        proc.executableURL = URL(fileURLWithPath: launch.executablePath)
        proc.arguments = launch.arguments
        if !launch.environment.isEmpty {
            proc.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
        }

        let attemptStartedAt = Date()

        let descriptors = try createPseudoTerminal(initialSize: pty)
        let masterFD = descriptors.master
        let slaveFD = descriptors.slave
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let stdinHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let stdoutFD = dup(slaveFD)
        let stderrFD = dup(slaveFD)
        guard stdoutFD >= 0, stderrFD >= 0 else {
            let reason = "ssh shell setup failed: \(String(cString: strerror(errno)))"
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            try? stdinHandle.close()
            if stdoutFD >= 0 { _ = Darwin.close(stdoutFD) }
            if stderrFD >= 0 { _ = Darwin.close(stderrFD) }
            throw SSHError.connectionFailed(reason)
        }

        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: true)
        proc.standardInput = stdinHandle
        proc.standardOutput = stdoutHandle
        proc.standardError = stderrHandle

        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.recordFailureProbeOutput(data)
            self?.handleInteractivePasswordAutofillIfNeeded(for: data)
            self?.onOutput?(data)
        }

        proc.terminationHandler = { [weak self] task in
            guard let self else { return }
            let snapshot = self.terminationSnapshot()
            self.cleanupHandles()
            Task {
                await self.handleProcessTermination(
                    status: task.terminationStatus,
                    output: snapshot.output,
                    attemptStartedAt: snapshot.startedAt,
                    compatibilityProfile: snapshot.profile
                )
            }
        }

        do {
            try proc.run()
        } catch {
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            cleanupHandles()
            onStateChange?(.failed(error.localizedDescription))
            throw SSHError.connectionFailed(error.localizedDescription)
        }

        stateQueue.sync {
            process = proc
            self.masterHandle = masterHandle
            masterFileDescriptor = masterFD
            activeCompatibilityProfile = compatibilityProfile
            activeAttemptStartedAt = attemptStartedAt
            recentFailureProbeBuffer.removeAll(keepingCapacity: true)
        }

        scheduleCompatibilityProfilePersistence(
            for: compatibilityProfile,
            processIdentifier: proc.processIdentifier
        )

        onStateChange?(.running)
    }

    public func write(_ data: Data) async throws {
        try writeSync(data)
    }

    public func resize(_ size: PTYSize) async throws {
        pty = size
        let state = stateQueue.sync { (masterFileDescriptor, process?.processIdentifier) }
        guard let masterFileDescriptor = state.0 else {
            throw SSHError.notConnected
        }

        var windowSize = makeWindowSize(from: size)
        let resizeResult = ioctl(masterFileDescriptor, TIOCSWINSZ, &windowSize)
        guard resizeResult == 0 else {
            let reason = String(cString: strerror(errno))
            throw SSHError.connectionFailed("resize failed: \(reason)")
        }

        if let processIdentifier = state.1, processIdentifier > 0 {
            _ = kill(pid_t(processIdentifier), SIGWINCH)
        }
    }

    public func stop() async {
        let currentProcess = stateQueue.sync { process }
        guard let currentProcess else {
            cleanupHandles()
            onStateChange?(.stopped)
            return
        }

        if currentProcess.isRunning {
            currentProcess.terminate()
            return
        }
        cleanupHandles()
        onStateChange?(.stopped)
    }

    private func writeSync(_ data: Data) throws {
        guard let masterHandle = stateQueue.sync(execute: { masterHandle }) else {
            throw SSHError.notConnected
        }

        do {
            try masterHandle.write(contentsOf: data)
        } catch {
            throw SSHError.connectionFailed("write failed: \(error.localizedDescription)")
        }
    }

    private func cleanupHandles() {
        compatibilityPersistenceTask?.cancel()
        compatibilityPersistenceTask = nil
        let currentHandle = stateQueue.sync { () -> FileHandle? in
            let handle = masterHandle
            masterHandle = nil
            masterFileDescriptor = nil
            process = nil
            activeAttemptStartedAt = nil
            interactivePromptBuffer.removeAll(keepingCapacity: true)
            interactivePasswordAutofillUsed = false

            return handle
        }

        currentHandle?.readabilityHandler = nil
        try? currentHandle?.close()
    }

    private struct TerminationSnapshot {
        var output: String
        var startedAt: Date
        var profile: SSHCompatibilityProfile
    }

    private func recordFailureProbeOutput(_ data: Data) {
        stateQueue.sync {
            recentFailureProbeBuffer.append(data)
            if recentFailureProbeBuffer.count > failureProbeBufferLimit {
                recentFailureProbeBuffer = recentFailureProbeBuffer.suffix(failureProbeBufferLimit)
            }
        }
    }

    private func terminationSnapshot() -> TerminationSnapshot {
        stateQueue.sync {
            TerminationSnapshot(
                output: String(decoding: recentFailureProbeBuffer, as: UTF8.self),
                startedAt: activeAttemptStartedAt ?? Date(),
                profile: activeCompatibilityProfile
            )
        }
    }

    private func handleInteractivePasswordAutofillIfNeeded(for data: Data) {
        let command: Data? = stateQueue.sync {
            guard skipAutoPasswordDelivery,
                  host.auth.method == .password,
                  !interactivePasswordAutofillUsed,
                  let cachedStoredPassword,
                  !cachedStoredPassword.isEmpty
            else {
                return nil
            }

            let chunk = String(decoding: data, as: UTF8.self)
            guard !chunk.isEmpty else { return nil }

            interactivePromptBuffer.append(chunk.lowercased())
            if interactivePromptBuffer.count > 4096 {
                interactivePromptBuffer = String(interactivePromptBuffer.suffix(4096))
            }

            if Self.looksLikeOTPChallenge(interactivePromptBuffer) {
                return nil
            }

            guard Self.looksLikePasswordPrompt(interactivePromptBuffer) else {
                return nil
            }

            interactivePasswordAutofillUsed = true
            interactivePromptBuffer.removeAll(keepingCapacity: true)
            return Data((cachedStoredPassword + "\n").utf8)
        }

        guard let command else { return }
        try? writeSync(command)
    }

    private static func looksLikePasswordPrompt(_ output: String) -> Bool {
        output.contains("password:")
    }

    private static func looksLikeOTPChallenge(_ output: String) -> Bool {
        output.contains("verification code")
            || output.contains("one-time password")
            || output.contains("otp")
            || output.contains("token code")
            || output.contains("authenticator code")
    }

    private func handleProcessTermination(
        status: Int32,
        output: String,
        attemptStartedAt: Date,
        compatibilityProfile: SSHCompatibilityProfile
    ) async {
        if status == 0 {
            onStateChange?(.stopped)
            return
        }

        let elapsed = Date().timeIntervalSince(attemptStartedAt)
        if elapsed <= compatibilityRetryWindow,
           let nextProfile = SSHCompatibilityPlanner.nextProfile(
                afterFailureOutput: output,
                currentProfile: compatibilityProfile,
                authMethod: host.auth.method
           ),
           nextProfile != compatibilityProfile {
            do {
                try await startProcess(using: nextProfile)
                return
            } catch {
                let message = error.localizedDescription
                onOutput?(Data((message + "\r\n").utf8))
                onStateChange?(.failed(message))
                return
            }
        }

        if !skipAutoPasswordDelivery,
           host.auth.method == .password,
           elapsed <= compatibilityRetryWindow,
           Self.looksLikeInteractiveAuthRetryCandidate(output) {
            skipAutoPasswordDelivery = true
            do {
                try await startProcess(using: compatibilityProfile)
                return
            } catch {
                let message = error.localizedDescription
                onOutput?(Data((message + "\r\n").utf8))
                onStateChange?(.failed(message))
                return
            }
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmedOutput.isEmpty ? "ssh exited with status \(status)" : trimmedOutput
        if trimmedOutput.isEmpty {
            onOutput?(Data((message + "\r\n").utf8))
        }
        onStateChange?(.failed(message))
    }

    private static func looksLikeInteractiveAuthRetryCandidate(_ output: String) -> Bool {
        let lower = output.lowercased()

        if lower.contains("keyboard-interactive") {
            return true
        }

        if lower.contains("one-time password")
            || lower.contains("verification code")
            || lower.contains("otp")
            || lower.contains("authenticator code")
            || lower.contains("token code")
        {
            return true
        }

        if lower.contains("too many authentication failures") {
            return true
        }

        if lower.contains("permission denied, please try again.")
            || lower.contains("permission denied (")
        {
            return true
        }

        if lower.contains("permission denied")
            && (lower.contains("password") || lower.contains("keyboard-interactive"))
        {
            return true
        }

        return false
    }

    private func scheduleCompatibilityProfilePersistence(
        for compatibilityProfile: SSHCompatibilityProfile,
        processIdentifier: Int32
    ) {
        compatibilityPersistenceTask?.cancel()
        let persistenceDelay = compatibilityPersistenceDelay
        compatibilityPersistenceTask = Task { [weak self, persistenceDelay] in
            try? await Task.sleep(for: persistenceDelay)
            guard let self, !Task.isCancelled else { return }

            let shouldPersist = self.stateQueue.sync {
                self.process?.processIdentifier == processIdentifier && self.process?.isRunning == true
            }
            guard shouldPersist else { return }

            await self.compatibilityProfileStore.recordSuccess(
                profile: compatibilityProfile,
                for: self.host,
                fingerprint: nil
            )
        }
    }

    private func createPseudoTerminal(initialSize: PTYSize) throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = makeWindowSize(from: initialSize)
        let result = openpty(&master, &slave, nil, nil, &windowSize)
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            throw SSHError.connectionFailed("openpty failed: \(reason)")
        }
        return (master: master, slave: slave)
    }

    private func makeWindowSize(from size: PTYSize) -> winsize {
        winsize(
            ws_row: UInt16(clamping: size.rows),
            ws_col: UInt16(clamping: size.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
    }

    private func makeLaunchConfiguration(
        compatibilityProfile: SSHCompatibilityProfile
    ) async -> LaunchConfiguration {
        if let launchConfigurationOverride {
            return launchConfigurationOverride
        }

        let storedPassword: String? = if host.auth.method == .password,
                                         let passwordReference = host.auth.passwordReference,
                                         !passwordReference.isEmpty,
                                         let password = await credentialStore.secret(for: passwordReference),
                                         !password.isEmpty {
            password
        } else {
            nil
        }
        stateQueue.sync {
            cachedStoredPassword = storedPassword
        }
        let hasStoredPassword = storedPassword != nil

        if host.auth.method == .password,
           !skipAutoPasswordDelivery,
           hasStoredPassword,
           let password = storedPassword,
           let launch = Self.makePasswordLaunchConfiguration(
                for: host,
                password: password,
                compatibilityProfile: compatibilityProfile
           )
        {
            return launch
        }

        let useConnectionReuse = SSHConnectionReusePolicy.shouldUseConnectionReuse(
            authMethod: host.auth.method,
            hasStoredPassword: hasStoredPassword
        )
        return Self.makeStandardLaunchConfiguration(
            for: host,
            useConnectionReuse: useConnectionReuse,
            compatibilityProfile: compatibilityProfile
        )
    }

    static func makeSSHArguments(
        for host: Host,
        useConnectionReuse: Bool = true,
        allocateTTY: Bool = true,
        remoteCommand: String? = nil,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) -> [String] {
        var args: [String] = [
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        if allocateTTY {
            args.insert("-tt", at: 0)
        }
        if useConnectionReuse {
            args.append(contentsOf: SSHConnectionReuse.masterOptions(for: host))
        }
        args.append(contentsOf: compatibilityProfile.additionalSSHOptions())

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=keyboard-interactive,password"])
            args.append(contentsOf: ["-o", "NumberOfPasswordPrompts=3"])
            args.append(contentsOf: ["-o", "PubkeyAuthentication=no"])
            args.append(contentsOf: ["-o", "GSSAPIAuthentication=no"])
            args.append(contentsOf: ["-o", "KbdInteractiveAuthentication=yes"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        if let remoteCommand, !remoteCommand.isEmpty {
            args.append(remoteCommand)
        }
        return args
    }

    static func makeStandardLaunchConfiguration(
        for host: Host,
        useConnectionReuse: Bool = true,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) -> LaunchConfiguration {
        wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(
                for: host,
                useConnectionReuse: useConnectionReuse,
                compatibilityProfile: compatibilityProfile
            ),
            environment: [:],
            wrapInScript: true
        )
    }

    static func makeRemoteCommandLaunchConfiguration(
        for host: Host,
        command: String,
        credentialStore: CredentialStore = CredentialStore(),
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) async -> LaunchConfiguration? {
        let storedPassword: String? = if host.auth.method == .password,
                                         let passwordReference = host.auth.passwordReference,
                                         !passwordReference.isEmpty,
                                         let password = await credentialStore.secret(for: passwordReference),
                                         !password.isEmpty {
            password
        } else {
            nil
        }
        let hasStoredPassword = storedPassword != nil
        let useConnectionReuse = SSHConnectionReusePolicy.shouldUseConnectionReuse(
            authMethod: host.auth.method,
            hasStoredPassword: hasStoredPassword
        )

        if host.auth.method == .password,
           let password = storedPassword,
           let launch = makePasswordLaunchConfiguration(
                for: host,
                password: password,
                remoteCommand: command,
                allocateTTY: false,
                compatibilityProfile: compatibilityProfile
           ) {
            return launch
        }

        return wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(
                for: host,
                useConnectionReuse: useConnectionReuse,
                allocateTTY: false,
                remoteCommand: command,
                compatibilityProfile: compatibilityProfile
            ),
            environment: [:],
            wrapInScript: false
        )
    }

    static func makePasswordLaunchConfiguration(
        for host: Host,
        password: String,
        sshpassPath: String? = defaultSSHPassPath(),
        askPassScriptPath: String? = ensureAskPassScriptPath(),
        remoteCommand: String? = nil,
        allocateTTY: Bool = true,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) -> LaunchConfiguration? {
        let wrapped = wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(
                for: host,
                useConnectionReuse: false,
                allocateTTY: allocateTTY,
                remoteCommand: remoteCommand,
                compatibilityProfile: compatibilityProfile
            ),
            environment: [:],
            wrapInScript: allocateTTY
        )

        if let sshpassPath {
            return LaunchConfiguration(
                executablePath: sshpassPath,
                arguments: ["-e", wrapped.executablePath] + wrapped.arguments,
                environment: ["SSHPASS": password]
            )
        }

        guard let askPassScriptPath else { return nil }
        return LaunchConfiguration(
            executablePath: wrapped.executablePath,
            arguments: wrapped.arguments,
            environment: [
                "SSH_ASKPASS": askPassScriptPath,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "remora-askpass",
                "REMORA_SSH_PASSWORD": password,
            ]
        )
    }

    private static func wrappedSSHLaunchConfiguration(
        sshArguments: [String],
        environment: [String: String],
        wrapInScript: Bool
    ) -> LaunchConfiguration {
        let sshPath = "/usr/bin/ssh"
        let environment = mergedTerminalEnvironment(environment)

        if wrapInScript, FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            return LaunchConfiguration(
                executablePath: "/usr/bin/script",
                arguments: ["-q", "/dev/null", sshPath] + sshArguments,
                environment: environment
            )
        }

        return LaunchConfiguration(
            executablePath: sshPath,
            arguments: sshArguments,
            environment: environment
        )
    }

    private static func mergedTerminalEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        let inheritedTerm = ProcessInfo.processInfo.environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            environment["TERM"] = (inheritedTerm?.isEmpty == false ? inheritedTerm : nil) ?? "xterm-256color"
        }

        return environment
    }

    private static func defaultSSHPassPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func ensureAskPassScriptPath() -> String? {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-ssh-askpass.sh")

        if FileManager.default.fileExists(atPath: scriptURL.path) {
            return scriptURL.path
        }

        let script = """
        #!/bin/sh
        printf '%s\\n' "${REMORA_SSH_PASSWORD}"
        """
        guard let scriptData = script.data(using: .utf8) else {
            return nil
        }

        do {
            try scriptData.write(to: scriptURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return scriptURL.path
        } catch {
            return nil
        }
    }
}
