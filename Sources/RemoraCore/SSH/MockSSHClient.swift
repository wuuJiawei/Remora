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
    private var commandBuffer: [Character] = []
    private var cursorIndex = 0

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

        let characters = Array(input)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\u{1B}" {
                index += handleEscapeSequence(in: characters, startingAt: index)
                continue
            }

            if character == "\u{3}" {
                commandBuffer.removeAll(keepingCapacity: true)
                cursorIndex = 0
                emit("^C\r\n")
                prompt()
                index += 1
                continue
            }

            if character == "\u{7F}" {
                deleteBackward()
                index += 1
                continue
            }

            if character == "\u{1}" {
                moveCursorToStart()
                index += 1
                continue
            }

            if character == "\u{5}" {
                moveCursorToEnd()
                index += 1
                continue
            }

            if character == "\u{B}" {
                deleteToEndOfLine()
                index += 1
                continue
            }

            if character == "\u{15}" {
                deleteEntireLine()
                index += 1
                continue
            }

            if character == "\r" || character == "\n" {
                let command = String(commandBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                commandBuffer.removeAll(keepingCapacity: true)
                cursorIndex = 0
                emit("\r\n")
                try await handle(command: command)
                prompt()
                index += 1
                continue
            }

            if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                index += 1
                continue
            }

            insert(character)
            index += 1
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

    private func insert(_ character: Character) {
        if cursorIndex == commandBuffer.count {
            commandBuffer.append(character)
            cursorIndex += 1
            emit(String(character))
            return
        }

        commandBuffer.insert(character, at: cursorIndex)
        cursorIndex += 1

        let tail = String(commandBuffer[(cursorIndex - 1) ..< commandBuffer.count])
        emit(tail)
        emitCursorLeft(count: max(0, commandBuffer.count - cursorIndex))
    }

    private func deleteBackward() {
        guard cursorIndex > 0 else { return }
        cursorIndex -= 1
        commandBuffer.remove(at: cursorIndex)

        emitCursorLeft(count: 1)
        let tail = String(commandBuffer[cursorIndex ..< commandBuffer.count]) + " "
        emit(tail)
        emitCursorLeft(count: tail.count)
    }

    private func deleteForward() {
        guard cursorIndex < commandBuffer.count else { return }
        commandBuffer.remove(at: cursorIndex)
        let tail = String(commandBuffer[cursorIndex ..< commandBuffer.count]) + " "
        emit(tail)
        emitCursorLeft(count: tail.count)
    }

    private func deleteToEndOfLine() {
        guard cursorIndex < commandBuffer.count else { return }
        let removedCount = commandBuffer.count - cursorIndex
        commandBuffer.removeSubrange(cursorIndex...)
        emit(String(repeating: " ", count: removedCount))
        emitCursorLeft(count: removedCount)
    }

    private func deleteEntireLine() {
        guard !commandBuffer.isEmpty else { return }
        emitCursorLeft(count: cursorIndex)
        emit(String(repeating: " ", count: commandBuffer.count))
        emitCursorLeft(count: commandBuffer.count)
        commandBuffer.removeAll(keepingCapacity: true)
        cursorIndex = 0
    }

    private func emitCursorLeft(count: Int) {
        guard count > 0 else { return }
        emit(String(repeating: "\u{1B}[D", count: count))
    }

    private func emitCursorRight(count: Int) {
        guard count > 0 else { return }
        emit(String(repeating: "\u{1B}[C", count: count))
    }

    private func moveCursorLeft(count: Int) {
        guard count > 0 else { return }
        cursorIndex = max(0, cursorIndex - count)
        emitCursorLeft(count: count)
    }

    private func moveCursorRight(count: Int) {
        guard count > 0 else { return }
        cursorIndex = min(commandBuffer.count, cursorIndex + count)
        emitCursorRight(count: count)
    }

    private func moveCursorToStart() {
        let distance = cursorIndex
        cursorIndex = 0
        emitCursorLeft(count: distance)
    }

    private func moveCursorToEnd() {
        let distance = commandBuffer.count - cursorIndex
        cursorIndex = commandBuffer.count
        emitCursorRight(count: distance)
    }

    private func handleEscapeSequence(in characters: [Character], startingAt index: Int) -> Int {
        guard index + 1 < characters.count else { return 1 }
        let introducer = characters[index + 1]

        if introducer == "[" {
            var cursor = index + 2
            var parameterBuffer = ""
            while cursor < characters.count {
                let character = characters[cursor]
                if character.isASCII, character.isLetter || character == "~" {
                    handleCSISequence(final: character, parameters: parameterBuffer)
                    return cursor - index + 1
                }
                parameterBuffer.append(character)
                cursor += 1
            }
            return characters.count - index
        }

        if introducer == "O", index + 2 < characters.count {
            handleSS3Sequence(final: characters[index + 2])
            return 3
        }

        return 1
    }

    private func handleCSISequence(final: Character, parameters: String) {
        switch final {
        case "C":
            moveCursorRight(count: 1)
        case "D":
            moveCursorLeft(count: 1)
        case "H":
            moveCursorToStart()
        case "F":
            moveCursorToEnd()
        case "~":
            if parameters.split(separator: ";").first == "3" {
                deleteForward()
            }
        default:
            break
        }
    }

    private func handleSS3Sequence(final: Character) {
        switch final {
        case "C":
            moveCursorRight(count: 1)
        case "D":
            moveCursorLeft(count: 1)
        case "H":
            moveCursorToStart()
        case "F":
            moveCursorToEnd()
        default:
            break
        }
    }

    private func emit(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        onOutput?(data)
    }
}
