import Foundation

public actor MockSSHClient: SSHTransportClientProtocol {
    private var connectedHost: Host?

    public init() {}

    public func connect(to host: Host) async throws {
        connectedHost = host
    }

    public func openShell(pty: PTYSize) async throws -> SSHTransportSessionProtocol {
        guard let host = connectedHost else {
            throw SSHError.notConnected
        }
        return MockShellSession(host: host, pty: pty)
    }

    public func disconnect() async {
        connectedHost = nil
    }
}

public final class MockShellSession: SSHTransportSessionProtocol, @unchecked Sendable {
    public var onOutput: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    private let host: Host
    private var pty: PTYSize
    private var isRunning = false
    private var commandBuffer = ""

    public init(host: Host, pty: PTYSize) {
        self.host = host
        self.pty = pty
    }

    public func start() async throws {
        isRunning = true
        onStateChange?(.running)
        emit("Connected to \(host.username)@\(host.address):\(host.port)\r\n")
        emit("Type commands and press Enter.\r\n")
        prompt()
    }

    public func write(_ data: Data) async throws {
        guard isRunning else { return }
        guard let input = String(data: data, encoding: .utf8) else { return }

        // Ignore ANSI navigation/control sequences from local key mapping in mock mode.
        if input.contains("\u{1B}") {
            return
        }

        for character in input {
            if character == "\u{3}" {
                commandBuffer.removeAll(keepingCapacity: true)
                emit("^C\r\n")
                prompt()
                continue
            }

            if character == "\u{7F}" {
                if !commandBuffer.isEmpty {
                    commandBuffer.removeLast()
                    emit("\u{8} \u{8}")
                }
                continue
            }

            if character == "\r" || character == "\n" {
                let command = commandBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                commandBuffer.removeAll(keepingCapacity: true)
                emit("\r\n")
                try await handle(command: command)
                prompt()
                continue
            }

            if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                continue
            }

            commandBuffer.append(character)
            emit(String(character))
        }
    }

    public func resize(_ size: PTYSize) async throws {
        pty = size
        emit("\r\n[pty resized to \(size.columns)x\(size.rows)]\r\n")
        prompt()
    }

    public func stop() async {
        isRunning = false
        onStateChange?(.stopped)
    }

    private func handle(command: String) async throws {
        switch command {
        case "":
            return
        case "clear":
            emit("\u{001B}[2J\u{001B}[H")
        case "help":
            emit("Available commands: help, date, whoami, ls, clear\r\n")
        case "date":
            emit("\(Date.now.formatted(date: .abbreviated, time: .standard))\r\n")
        case "whoami":
            emit("\(host.username)\r\n")
        case "ls":
            emit("app.log  releases  config.yml\r\n")
        default:
            emit("zsh: command not found: \(command)\r\n")
        }
    }

    private func prompt() {
        emit("\(host.username)@\(host.name) % ")
    }

    private func emit(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        onOutput?(data)
    }
}
