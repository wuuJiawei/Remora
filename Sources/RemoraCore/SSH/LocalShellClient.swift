import Foundation
import Darwin

enum LocalShellInterruptSignalTarget: Equatable {
    case processGroup(pid_t)
    case process(pid_t)
}

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
    private var masterHandle: FileHandle?
    private var masterFileDescriptor: Int32?
    private let stateQueue = DispatchQueue(label: "io.lighting-tech.remora.local-shell.session")

    public init(host: Host, pty: PTYSize) {
        self.host = host
        self.pty = pty
    }

    public func start() async throws {
        let shouldStart = stateQueue.sync { process == nil }
        guard shouldStart else { return }

        let descriptors = try createPseudoTerminal(initialSize: pty)
        let masterFD = descriptors.master
        let slaveFD = descriptors.slave
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let stdinHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)

        let stdoutFD = dup(slaveFD)
        let stderrFD = dup(slaveFD)
        guard stdoutFD >= 0, stderrFD >= 0 else {
            let reason = "local shell setup failed: \(String(cString: strerror(errno)))"
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            try? stdinHandle.close()
            if stdoutFD >= 0 { _ = Darwin.close(stdoutFD) }
            if stderrFD >= 0 { _ = Darwin.close(stderrFD) }
            throw SSHError.connectionFailed(reason)
        }

        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-i"]
        proc.environment = mergedEnvironment(proc.environment)
        proc.standardInput = stdinHandle
        proc.standardOutput = stdoutHandle
        proc.standardError = stderrHandle

        masterHandle.readabilityHandler = { [weak self] handle in
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
        }

        onStateChange?(.running)
        onOutput?(Data("Connected to local zsh shell\r\nType commands and press Enter.\r\n".utf8))
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
            sendInterruptSignalIfNeeded(for: data)
        } catch {
            throw SSHError.connectionFailed("write failed: \(error.localizedDescription)")
        }
    }

    private func sendInterruptSignalIfNeeded(for data: Data) {
        guard data.contains(0x03) else { return } // Ctrl-C / ETX

        let appProcessGroup = getpgrp()
        let state = stateQueue.sync { () -> (foregroundProcessGroup: pid_t?, shellProcessID: pid_t?, shellProcessGroup: pid_t?) in
            let foreground = masterFileDescriptor.flatMap { fd -> pid_t? in
                let value = tcgetpgrp(fd)
                return value > 0 ? value : nil
            }
            let shellPID = process?.processIdentifier
            let shellGroup = shellPID.flatMap { pid -> pid_t? in
                let value = getpgid(pid)
                return value > 0 ? value : nil
            }
            return (foreground, shellPID, shellGroup)
        }

        let targets = Self.interruptSignalTargets(
            foregroundProcessGroup: state.foregroundProcessGroup,
            shellProcessID: state.shellProcessID,
            shellProcessGroup: state.shellProcessGroup,
            appProcessGroup: appProcessGroup
        )

        for target in targets {
            let result: Int32 = {
                switch target {
                case .processGroup(let processGroup):
                    return kill(-processGroup, SIGINT)
                case .process(let process):
                    return kill(process, SIGINT)
                }
            }()
            if result == 0 {
                break
            }
        }
    }

    static func interruptSignalTargets(
        foregroundProcessGroup: pid_t?,
        shellProcessID: pid_t?,
        shellProcessGroup: pid_t?,
        appProcessGroup: pid_t
    ) -> [LocalShellInterruptSignalTarget] {
        var targets: [LocalShellInterruptSignalTarget] = []

        if let foregroundProcessGroup,
           foregroundProcessGroup > 0,
           foregroundProcessGroup != appProcessGroup
        {
            targets.append(.processGroup(foregroundProcessGroup))
        }

        if let shellProcessGroup,
           shellProcessGroup > 0,
           shellProcessGroup != appProcessGroup,
           !targets.contains(.processGroup(shellProcessGroup))
        {
            targets.append(.processGroup(shellProcessGroup))
        }

        if let shellProcessID, shellProcessID > 0 {
            targets.append(.process(shellProcessID))
        }

        return targets
    }

    private func cleanupHandles() {
        let currentHandle = stateQueue.sync { () -> FileHandle? in
            let handle = masterHandle
            masterHandle = nil
            masterFileDescriptor = nil
            process = nil
            return handle
        }

        currentHandle?.readabilityHandler = nil
        try? currentHandle?.close()
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
}
