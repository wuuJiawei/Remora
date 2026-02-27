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
    public var onOutput: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    private let host: Host
    private var pty: PTYSize
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pendingPassword: String?
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
        let launch = Self.makeLaunchConfiguration(for: host)
        proc.executableURL = URL(fileURLWithPath: launch.executablePath)
        proc.arguments = launch.arguments

        if host.auth.method == .password,
           let passwordReference = host.auth.passwordReference,
           !passwordReference.isEmpty
        {
            pendingPassword = await credentialStore.secret(for: passwordReference)
        } else {
            pendingPassword = nil
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
            self?.handlePasswordPromptIfNeeded(from: data)
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onOutput?(data)
            self?.handlePasswordPromptIfNeeded(from: data)
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
        pendingPassword = nil
    }

    private func handlePasswordPromptIfNeeded(from data: Data) {
        guard let password = pendingPassword, !password.isEmpty else { return }
        let output = String(decoding: data, as: UTF8.self).lowercased()
        guard output.contains("password:") else { return }

        do {
            try writeSync(Data((password + "\n").utf8))
            pendingPassword = nil
        } catch {
            onOutput?(Data(("password autofill failed: \(error.localizedDescription)\r\n").utf8))
        }
    }

    static func makeSSHArguments(for host: Host) -> [String] {
        var args: [String] = [
            "-tt",
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        args.append(contentsOf: SSHConnectionReuse.options(for: host))

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        return args
    }

    static func makeLaunchConfiguration(for host: Host) -> (executablePath: String, arguments: [String]) {
        let sshPath = "/usr/bin/ssh"
        let sshArguments = makeSSHArguments(for: host)

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            return (
                executablePath: "/usr/bin/script",
                arguments: ["-q", "/dev/null", sshPath] + sshArguments
            )
        }

        return (executablePath: sshPath, arguments: sshArguments)
    }
}
