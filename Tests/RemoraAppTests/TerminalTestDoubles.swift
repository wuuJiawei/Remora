import Foundation
import RemoraCore

actor TerminalCommandRecorder {
    private(set) var commands: [String] = []
    private(set) var resizeRequests: [PTYSize] = []

    func append(_ command: String) {
        commands.append(command)
    }

    func appendResize(_ size: PTYSize) {
        resizeRequests.append(size)
    }

    func reset() {
        commands.removeAll(keepingCapacity: false)
        resizeRequests.removeAll(keepingCapacity: false)
    }
}

actor RecordingSSHClient: SSHTransportClientProtocol {
    private let recorder: TerminalCommandRecorder
    private let initialDirectory: String
    private var connectedHost: RemoraCore.Host?

    init(recorder: TerminalCommandRecorder, initialDirectory: String = "/") {
        self.recorder = recorder
        self.initialDirectory = initialDirectory
    }

    func connect(to host: RemoraCore.Host) async throws {
        connectedHost = host
    }

    func openShell(pty: PTYSize) async throws -> SSHTransportSessionProtocol {
        guard let host = connectedHost else {
            throw SSHError.notConnected
        }
        return RecordingShellSession(
            host: host,
            pty: pty,
            recorder: recorder,
            initialDirectory: initialDirectory
        )
    }

    func disconnect() async {
        connectedHost = nil
    }
}

final class RecordingShellSession: SSHTransportSessionProtocol, @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    private let host: RemoraCore.Host
    private var pty: PTYSize
    private let recorder: TerminalCommandRecorder
    private var currentDirectory: String
    private var commandBuffer = ""
    private var isRunning = false

    init(host: RemoraCore.Host, pty: PTYSize, recorder: TerminalCommandRecorder, initialDirectory: String) {
        self.host = host
        self.pty = pty
        self.recorder = recorder
        self.currentDirectory = initialDirectory
    }

    func start() async throws {
        isRunning = true
        onStateChange?(.running)
        emit("Connected to \(host.username)@\(host.address):\(host.port)\r\n")
    }

    func write(_ data: Data) async throws {
        guard isRunning else { return }
        guard let input = String(data: data, encoding: .utf8) else { return }

        for character in input {
            if character == "\r" || character == "\n" {
                let command = commandBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                commandBuffer.removeAll(keepingCapacity: true)
                guard !command.isEmpty else { continue }
                await recorder.append(command)
                try await handle(command)
                continue
            }

            if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                continue
            }

            commandBuffer.append(character)
        }
    }

    func resize(_ size: PTYSize) async throws {
        pty = size
        await recorder.appendResize(size)
    }

    func stop() async {
        isRunning = false
        onStateChange?(.stopped)
    }

    private func handle(_ command: String) async throws {
        if command == "pwd" {
            emit("\(currentDirectory)\r\n")
            return
        }

        guard command.hasPrefix("cd ") else { return }
        let argument = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard let parsedDirectory = parseShellSingleQuoted(argument), !parsedDirectory.isEmpty else { return }
        currentDirectory = parsedDirectory
    }

    private func parseShellSingleQuoted(_ value: String) -> String? {
        guard value.count >= 2, value.first == "'", value.last == "'" else { return nil }
        let inner = value.dropFirst().dropLast()
        return String(inner).replacingOccurrences(of: "'\\''", with: "'")
    }

    private func emit(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        onOutput?(data)
    }
}
