import Foundation

public actor LocalShellClient: SSHTransportClientProtocol {
    private var connectedHost: Host?

    public init() {}

    public func connect(to host: Host) async throws {
        connectedHost = host
    }

    public func openShell(pty: PTYSize) async throws -> SSHTransportSessionProtocol {
        guard let host = connectedHost else {
            throw SSHError.notConnected
        }
        return LocalShellSession(host: host, pty: pty)
    }

    public func disconnect() async {
        connectedHost = nil
    }
}

public final class LocalShellSession: SSHTransportSessionProtocol, @unchecked Sendable {
    public var onOutput: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    private let host: Host
    private var pty: PTYSize
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let stateQueue = DispatchQueue(label: "io.lighting-tech.remora.local-shell.session")

    public init(host: Host, pty: PTYSize) {
        self.host = host
        self.pty = pty
    }

    public func start() async throws {
        let shouldStart = stateQueue.sync { process == nil }
        guard shouldStart else { return }

        let proc = Process()
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            proc.arguments = ["-q", "/dev/null", "/bin/zsh", "-i"]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-i"]
        }
        proc.environment = mergedEnvironment(proc.environment)

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

            let message = "local shell exited with status \(task.terminationStatus)"
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
        onOutput?(Data("Connected to local zsh shell\r\nType commands and press Enter.\r\n".utf8))
    }

    public func write(_ data: Data) async throws {
        try writeSync(data)
    }

    public func resize(_ size: PTYSize) async throws {
        pty = size
        try writeSync(Data("stty cols \(size.columns) rows \(size.rows)\n".utf8))
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

    private func mergedEnvironment(_ base: [String: String]?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let base {
            env.merge(base) { _, new in new }
        }
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["PROMPT_EOL_MARK"] = ""
        return env
    }
}
