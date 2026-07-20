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
    typealias LaunchConfiguration = OpenSSHLaunchConfiguration
    typealias LaunchPlan = OpenSSHLaunchPlan

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (ShellSessionState) -> Void)?
    public var usesStoredPasswordDelivery: Bool {
        stateQueue.sync { activeLaunchUsesStoredPasswordDelivery }
    }

    private let host: Host
    private let launchConfigurationOverride: LaunchConfiguration?
    private let interactivePasswordAutofillOverride: String?
    private let compatibilityProfileStore: SSHCompatibilityProfileStore
    private var pty: PTYSize
    private var process: Process?
    private var masterHandle: FileHandle?
    private var masterFileDescriptor: Int32?
    private let credentialStore = CredentialStore()
    private let stateQueue = DispatchQueue(label: "io.lighting-tech.remora.ssh.session")
    private let outputQueue = DispatchQueue(label: "io.lighting-tech.remora.ssh.session.output")
    private let compatibilityRetryWindow: TimeInterval = 3
    private let interactivePasswordAutofillWindow: TimeInterval
    private let compatibilityPersistenceDelay: Duration = .seconds(1)
    private let failureProbeBufferLimit = 16 * 1024
    private var activeCompatibilityProfile = SSHCompatibilityProfile()
    private var recentFailureProbeBuffer = Data()
    private var activeAttemptStartedAt: Date?
    private var compatibilityPersistenceTask: Task<Void, Never>?
    private var skipAutoPasswordDelivery = false
    private var cachedStoredPassword: String?
    private var interactivePasswordAutofill: String?
    private var hasSubmittedInteractivePassword = false
    private var authPromptProbeTail = ""
    private var interactivePasswordAutofillDeadline: Date?
    private var hasRetriedWithoutConnectionReuse = false
    private var activeLaunchUsesStoredPasswordDelivery = false
    private var hasObservedOTPChallenge = false
    private var isStopping = false

    public init(host: Host, pty: PTYSize) {
        self.host = host
        self.launchConfigurationOverride = nil
        self.interactivePasswordAutofillOverride = nil
        self.compatibilityProfileStore = .shared
        self.pty = pty
        self.interactivePasswordAutofillWindow = 15
    }

    init(
        host: Host,
        pty: PTYSize,
        launchConfigurationOverride: LaunchConfiguration?,
        interactivePasswordAutofillOverride: String? = nil,
        interactivePasswordAutofillWindow: TimeInterval = 15,
        initialSkipAutoPasswordDelivery: Bool = false,
        cachedStoredPasswordOverride: String? = nil,
        compatibilityProfileStore: SSHCompatibilityProfileStore = .shared
    ) {
        self.host = host
        self.launchConfigurationOverride = launchConfigurationOverride
        self.interactivePasswordAutofillOverride = interactivePasswordAutofillOverride
        self.compatibilityProfileStore = compatibilityProfileStore
        self.pty = pty
        self.interactivePasswordAutofillWindow = interactivePasswordAutofillWindow
        self.skipAutoPasswordDelivery = initialSkipAutoPasswordDelivery
        self.cachedStoredPassword = cachedStoredPasswordOverride
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
        let shouldDisableConnectionReuse = stateQueue.sync { hasRetriedWithoutConnectionReuse }

        let proc = Process()
        let launchPlan = await makeLaunchPlan(compatibilityProfile: compatibilityProfile)
        let launch = shouldDisableConnectionReuse
            ? Self.launchConfigurationWithoutConnectionReuse(launchPlan.configuration)
            : launchPlan.configuration
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
            guard let self else { return }
            self.outputQueue.async { [weak self] in
                guard let self else { return }
                self.drainAvailableOutput(fileDescriptor: handle.fileDescriptor)
            }
        }

        proc.terminationHandler = { [weak self] task in
            guard let self else { return }
            masterHandle.readabilityHandler = nil
            let snapshot = self.outputQueue.sync {
                self.drainAvailableOutput(fileDescriptor: masterFD)
                return self.terminationSnapshot()
            }
            self.cleanupHandles()
            Task {
                await self.handleProcessTermination(
                    status: task.terminationStatus,
                    output: snapshot.output,
                    attemptStartedAt: snapshot.startedAt,
                    compatibilityProfile: snapshot.profile,
                    hasObservedOTPChallenge: snapshot.hasObservedOTPChallenge
                )
            }
        }

        stateQueue.sync {
            process = proc
            isStopping = false
            self.masterHandle = masterHandle
            masterFileDescriptor = masterFD
            activeCompatibilityProfile = compatibilityProfile
            activeAttemptStartedAt = attemptStartedAt
            recentFailureProbeBuffer.removeAll(keepingCapacity: true)
            hasObservedOTPChallenge = false
            interactivePasswordAutofill = launchPlan.interactivePasswordAutofill
            hasSubmittedInteractivePassword = false
            authPromptProbeTail.removeAll(keepingCapacity: true)
            interactivePasswordAutofillDeadline = skipAutoPasswordDelivery
                ? attemptStartedAt.addingTimeInterval(interactivePasswordAutofillWindow)
                : nil
            activeLaunchUsesStoredPasswordDelivery = launchPlan.interactivePasswordAutofill != nil
                || launchPlan.configuration.environment["SSHPASS"] != nil
                || launchPlan.configuration.environment["REMORA_SSH_PASSWORD"] != nil
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

        guard stateQueue.sync(execute: { process === proc }) else { return }

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
        let currentProcess = stateQueue.sync {
            isStopping = true
            return process
        }
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
            interactivePasswordAutofill = nil
            hasSubmittedInteractivePassword = false
            authPromptProbeTail.removeAll(keepingCapacity: false)
            interactivePasswordAutofillDeadline = nil

            return handle
        }

        currentHandle?.readabilityHandler = nil
        try? currentHandle?.close()
    }

    private struct TerminationSnapshot {
        var output: String
        var startedAt: Date
        var profile: SSHCompatibilityProfile
        var hasObservedOTPChallenge: Bool
    }

    private func recordFailureProbeOutput(_ data: Data) {
        stateQueue.sync {
            recentFailureProbeBuffer.append(data)
            if recentFailureProbeBuffer.count > failureProbeBufferLimit {
                recentFailureProbeBuffer = recentFailureProbeBuffer.suffix(failureProbeBufferLimit)
            }
            let probeText = String(decoding: recentFailureProbeBuffer.suffix(512), as: UTF8.self).lowercased()
            if Self.looksLikeOTPChallenge(probeText) {
                hasObservedOTPChallenge = true
            }
        }
    }

    private func handleProcessOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        recordFailureProbeOutput(data)
        attemptInteractivePasswordAutofillIfNeeded(from: data)
        onOutput?(data)
    }

    private func drainAvailableOutput(fileDescriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            guard Darwin.poll(&descriptor, 1, 0) > 0 else { return }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else { return }
            handleProcessOutput(Data(buffer.prefix(count)))
        }
    }

    private func terminationSnapshot() -> TerminationSnapshot {
        stateQueue.sync {
            TerminationSnapshot(
                output: String(decoding: recentFailureProbeBuffer, as: UTF8.self),
                startedAt: activeAttemptStartedAt ?? Date(),
                profile: activeCompatibilityProfile,
                hasObservedOTPChallenge: hasObservedOTPChallenge
            )
        }
    }

    private func attemptInteractivePasswordAutofillIfNeeded(from data: Data) {
        let password = stateQueue.sync { () -> String? in
            guard let interactivePasswordAutofill, hasSubmittedInteractivePassword == false else {
                return nil
            }

            authPromptProbeTail.append(String(decoding: data, as: UTF8.self))
            if authPromptProbeTail.count > 512 {
                authPromptProbeTail = String(authPromptProbeTail.suffix(512))
            }

            let lowercasedProbeTail = authPromptProbeTail.lowercased()

            if skipAutoPasswordDelivery, let interactivePasswordAutofillDeadline {
                guard Date() <= interactivePasswordAutofillDeadline else {
                    hasSubmittedInteractivePassword = true
                    authPromptProbeTail.removeAll(keepingCapacity: true)
                    self.interactivePasswordAutofillDeadline = nil
                    return nil
                }
            }

            let promptLine = Self.currentAuthenticationPromptLine(in: lowercasedProbeTail)
            guard !Self.looksLikeOTPChallenge(promptLine),
                  Self.detectPasswordPrompt(in: promptLine)
            else {
                return nil
            }

            hasSubmittedInteractivePassword = true
            self.interactivePasswordAutofillDeadline = nil
            return interactivePasswordAutofill
        }

        guard let password else { return }
        try? writeSync(Data((password + "\n").utf8))
    }

    private static func looksLikeOTPChallenge(_ output: String) -> Bool {
        output.contains("verification code")
            || output.contains("one-time password")
            || output.contains("email code")
            || output.contains("mfa code")
            || output.contains("otp")
            || output.contains("token code")
            || output.contains("authenticator code")
    }

    private func handleProcessTermination(
        status: Int32,
        output: String,
        attemptStartedAt: Date,
        compatibilityProfile: SSHCompatibilityProfile,
        hasObservedOTPChallenge: Bool
    ) async {
        if stateQueue.sync(execute: { isStopping }) {
            onStateChange?(.stopped)
            return
        }

        if status == 0 {
            onStateChange?(.stopped)
            return
        }

        let elapsed = Date().timeIntervalSince(attemptStartedAt)
        if elapsed <= compatibilityRetryWindow,
           !stateQueue.sync(execute: { hasRetriedWithoutConnectionReuse }),
           Self.isControlMasterFailure(output)
        {
            SSHConnectionReuse.removeControlPath(for: host, purpose: .shell)
            stateQueue.sync {
                hasRetriedWithoutConnectionReuse = true
            }
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
           !hasObservedOTPChallenge,
           stateQueue.sync(execute: { cachedStoredPassword?.isEmpty == false }),
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
            || lower.contains("email code")
            || lower.contains("mfa code")
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

    static func isControlMasterFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("mux_client_request_session")
            || lower.contains("session open refused")
            || lower.contains("control socket")
            || lower.contains("mux_client")
            || lower.contains("muxserver")
            || lower.contains("broken pipe")
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

    private func makeLaunchPlan(
        compatibilityProfile: SSHCompatibilityProfile
    ) async -> LaunchPlan {
        if let launchConfigurationOverride {
            return LaunchPlan(
                configuration: launchConfigurationOverride,
                interactivePasswordAutofill: interactivePasswordAutofillOverride ?? cachedStoredPassword
            )
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
        return Self.makeShellLaunchPlan(
            for: host,
            storedPassword: storedPassword,
            compatibilityProfile: compatibilityProfile,
            skipAutoPasswordDelivery: skipAutoPasswordDelivery
        )
    }

    static func makeShellLaunchPlan(
        for host: Host,
        storedPassword: String?,
        sshpassPath: String? = defaultSSHPassPath(),
        askPassScriptPath: String? = ensureAskPassScriptPath(),
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile(),
        skipAutoPasswordDelivery: Bool = false
    ) -> LaunchPlan {
        OpenSSHLaunchBuilder.makeShellLaunchPlan(
            for: host,
            storedPassword: storedPassword,
            sshpassPath: sshpassPath,
            askPassScriptPath: askPassScriptPath,
            compatibilityProfile: compatibilityProfile,
            skipAutoPasswordDelivery: skipAutoPasswordDelivery
        )
    }

    static func makeSSHArguments(
        for host: Host,
        useConnectionReuse: Bool = false,
        allocateTTY: Bool = true,
        remoteCommand: String? = nil,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) -> [String] {
        OpenSSHLaunchBuilder.makeSSHArguments(
            for: host,
            useConnectionReuse: useConnectionReuse,
            allocateTTY: allocateTTY,
            remoteCommand: remoteCommand,
            compatibilityProfile: compatibilityProfile
        )
    }

    static func makeStandardLaunchConfiguration(
        for host: Host,
        useConnectionReuse: Bool = true,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) -> LaunchConfiguration {
        OpenSSHLaunchBuilder.makeStandardLaunchConfiguration(
            for: host,
            useConnectionReuse: useConnectionReuse,
            compatibilityProfile: compatibilityProfile
        )
    }

    static func makeRemoteCommandLaunchConfiguration(
        for host: Host,
        command: String,
        credentialStore: CredentialStore = CredentialStore(),
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) async -> LaunchConfiguration? {
        await OpenSSHLaunchBuilder.makeRemoteCommandLaunchConfiguration(
            for: host,
            command: command,
            credentialStore: credentialStore,
            compatibilityProfile: compatibilityProfile
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
        OpenSSHLaunchBuilder.makePasswordLaunchConfiguration(
            for: host,
            password: password,
            sshpassPath: sshpassPath,
            askPassScriptPath: askPassScriptPath,
            remoteCommand: remoteCommand,
            allocateTTY: allocateTTY,
            compatibilityProfile: compatibilityProfile
        )
    }

    static func detectPasswordPrompt(in lowercasedText: String) -> Bool {
        lowercasedText.contains("password:")
            || lowercasedText.contains("password for ")
            || lowercasedText.contains("userauth_passwd")
    }

    private static func currentAuthenticationPromptLine(in lowercasedText: String) -> String {
        let normalized = lowercasedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    private static func wrappedSSHLaunchConfiguration(
        sshArguments: [String],
        environment: [String: String],
        wrapInScript: Bool
    ) -> LaunchConfiguration {
        OpenSSHLaunchBuilder.wrappedSSHLaunchConfiguration(
            sshArguments: sshArguments,
            environment: environment,
            wrapInScript: wrapInScript
        )
    }

    static func launchConfigurationWithoutConnectionReuse(
        _ configuration: OpenSSHLaunchConfiguration
    ) -> OpenSSHLaunchConfiguration {
        var arguments: [String] = []
        var index = 0
        while index < configuration.arguments.count {
            let argument = configuration.arguments[index]
            if argument == "-o",
               configuration.arguments.indices.contains(index + 1)
            {
                let option = configuration.arguments[index + 1]
                if !Self.isConnectionReuseOption(option) {
                    arguments.append(argument)
                    arguments.append(option)
                }
                index += 2
                continue
            }
            arguments.append(argument)
            index += 1
        }
        return OpenSSHLaunchConfiguration(
            executablePath: configuration.executablePath,
            arguments: arguments,
            environment: configuration.environment
        )
    }

    private static func isConnectionReuseOption(_ argument: String) -> Bool {
        argument.hasPrefix("ControlMaster=")
            || argument.hasPrefix("ControlPath=")
            || argument.hasPrefix("ControlPersist=")
    }

    private static func mergedTerminalEnvironment(_ base: [String: String]) -> [String: String] {
        OpenSSHLaunchBuilder.mergedTerminalEnvironment(base)
    }

    private static func defaultSSHPassPath() -> String? {
        OpenSSHLaunchBuilder.defaultSSHPassPath()
    }

    public static func hasSSHPassInstalled() -> Bool {
        defaultSSHPassPath() != nil
    }

    private static func ensureAskPassScriptPath() -> String? {
        OpenSSHLaunchBuilder.ensureAskPassScriptPath()
    }
}
