import Foundation

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
    private var pty: PTYSize
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let credentialStore = CredentialStore()
    private let stateQueue = DispatchQueue(label: "io.lighting-tech.remora.ssh.session")

    public init(host: Host, pty: PTYSize) {
        self.host = host
        self.pty = pty
    }

    public func start() async throws {
        let shouldStart = stateQueue.sync { process == nil }
        guard shouldStart else {
            return
        }

        let proc = Process()
        let launch = await makeLaunchConfiguration()
        proc.executableURL = URL(fileURLWithPath: launch.executablePath)
        proc.arguments = launch.arguments
        if !launch.environment.isEmpty {
            proc.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onOutput?(data)
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onOutput?(data)
        }

        proc.terminationHandler = { [weak self] task in
            self?.cleanupHandles()
            guard let self else { return }

            if task.terminationStatus == 0 {
                self.onStateChange?(.stopped)
                return
            }

            let message = "ssh exited with status \(task.terminationStatus)"
            self.onOutput?(Data((message + "\r\n").utf8))
            self.onStateChange?(.failed(message))
        }

        do {
            try proc.run()
        } catch {
            cleanupHandles()
            onStateChange?(.failed(error.localizedDescription))
            throw SSHError.connectionFailed(error.localizedDescription)
        }

        stateQueue.sync {
            process = proc
            stdinPipe = inPipe
            stdoutPipe = outPipe
            stderrPipe = errPipe
        }

        onStateChange?(.running)
    }

    public func write(_ data: Data) async throws {
        try writeSync(data)
    }

    public func resize(_ size: PTYSize) async throws {
        pty = size
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
        guard let stdinPipe = stateQueue.sync(execute: { stdinPipe }) else {
            throw SSHError.notConnected
        }

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw SSHError.connectionFailed("write failed: \(error.localizedDescription)")
        }
    }

    private func cleanupHandles() {
        let handles = stateQueue.sync { () -> (Pipe?, Pipe?, Pipe?) in
            let currentIn = stdinPipe
            let currentOut = stdoutPipe
            let currentErr = stderrPipe

            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            process = nil

            return (currentIn, currentOut, currentErr)
        }

        handles.1?.fileHandleForReading.readabilityHandler = nil
        handles.2?.fileHandleForReading.readabilityHandler = nil

        try? handles.0?.fileHandleForWriting.close()
        try? handles.1?.fileHandleForReading.close()
        try? handles.2?.fileHandleForReading.close()
    }

    private func makeLaunchConfiguration() async -> LaunchConfiguration {
        if host.auth.method == .password,
           let passwordReference = host.auth.passwordReference,
           !passwordReference.isEmpty,
           let password = await credentialStore.secret(for: passwordReference),
           !password.isEmpty,
           let launch = Self.makePasswordLaunchConfiguration(for: host, password: password)
        {
            return launch
        }

        let useConnectionReuse = host.auth.method != .password
        return Self.makeStandardLaunchConfiguration(for: host, useConnectionReuse: useConnectionReuse)
    }

    static func makeSSHArguments(for host: Host, useConnectionReuse: Bool = true) -> [String] {
        var args: [String] = [
            "-tt",
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        if useConnectionReuse {
            args.append(contentsOf: SSHConnectionReuse.masterOptions(for: host))
        }

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
            args.append(contentsOf: ["-o", "NumberOfPasswordPrompts=1"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        return args
    }

    static func makeStandardLaunchConfiguration(for host: Host, useConnectionReuse: Bool = true) -> LaunchConfiguration {
        wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(for: host, useConnectionReuse: useConnectionReuse),
            environment: [:]
        )
    }

    static func makePasswordLaunchConfiguration(
        for host: Host,
        password: String,
        sshpassPath: String? = defaultSSHPassPath(),
        askPassScriptPath: String? = ensureAskPassScriptPath()
    ) -> LaunchConfiguration? {
        let wrapped = wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(for: host, useConnectionReuse: false),
            environment: [:]
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
        environment: [String: String]
    ) -> LaunchConfiguration {
        let sshPath = "/usr/bin/ssh"
        let environment = mergedTerminalEnvironment(environment)

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
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
