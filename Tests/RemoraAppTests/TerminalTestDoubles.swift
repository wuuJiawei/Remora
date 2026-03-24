import Foundation
import RemoraCore

actor TerminalCommandRecorder {
    private(set) var commands: [String] = []
    private(set) var rawWrites: [String] = []
    private(set) var resizeRequests: [PTYSize] = []

    func append(_ command: String) {
        commands.append(command)
    }

    func appendRawWrite(_ text: String) {
        rawWrites.append(text)
    }

    func appendResize(_ size: PTYSize) {
        resizeRequests.append(size)
    }

    func reset() {
        commands.removeAll(keepingCapacity: false)
        rawWrites.removeAll(keepingCapacity: false)
        resizeRequests.removeAll(keepingCapacity: false)
    }
}

actor RecordingSSHClient: SSHTransportClientProtocol {
    enum PwdOutputStyle: Sendable {
        case plain
        case ansiWrapped
    }

    enum WorkingDirectoryEventStyle: Sendable {
        case none
        case osc7OnPrompt
        case osc7WithSTTerminatorAndPromptNoise
    }

    private let recorder: TerminalCommandRecorder
    private let initialDirectory: String
    private let pwdOutputStyle: PwdOutputStyle
    private let workingDirectoryEventStyle: WorkingDirectoryEventStyle
    private var connectedHost: RemoraCore.Host?

    init(
        recorder: TerminalCommandRecorder,
        initialDirectory: String = "/",
        pwdOutputStyle: PwdOutputStyle = .plain,
        workingDirectoryEventStyle: WorkingDirectoryEventStyle = .none
    ) {
        self.recorder = recorder
        self.initialDirectory = initialDirectory
        self.pwdOutputStyle = pwdOutputStyle
        self.workingDirectoryEventStyle = workingDirectoryEventStyle
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
            initialDirectory: initialDirectory,
            pwdOutputStyle: pwdOutputStyle,
            workingDirectoryEventStyle: workingDirectoryEventStyle
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
    private let pwdOutputStyle: RecordingSSHClient.PwdOutputStyle
    private let workingDirectoryEventStyle: RecordingSSHClient.WorkingDirectoryEventStyle
    private var commandBuffer = ""
    private var isRunning = false

    init(
        host: RemoraCore.Host,
        pty: PTYSize,
        recorder: TerminalCommandRecorder,
        initialDirectory: String,
        pwdOutputStyle: RecordingSSHClient.PwdOutputStyle,
        workingDirectoryEventStyle: RecordingSSHClient.WorkingDirectoryEventStyle
    ) {
        self.host = host
        self.pty = pty
        self.recorder = recorder
        self.currentDirectory = initialDirectory
        self.pwdOutputStyle = pwdOutputStyle
        self.workingDirectoryEventStyle = workingDirectoryEventStyle
    }

    func start() async throws {
        isRunning = true
        onStateChange?(.running)
        emit("Connected to \(host.username)@\(host.address):\(host.port)\r\n")
        emitWorkingDirectoryIfNeeded()
    }

    func write(_ data: Data) async throws {
        guard isRunning else { return }
        guard let input = String(data: data, encoding: .utf8) else { return }
        await recorder.appendRawWrite(input)

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
            switch pwdOutputStyle {
            case .plain:
                emit("\(currentDirectory)\r\n")
            case .ansiWrapped:
                emit("\u{001B}[?2004l\(currentDirectory)\r\n\u{001B}[?2004h")
            }
            emitWorkingDirectoryIfNeeded()
            return
        }

        if command.hasPrefix("cd ") {
            let argument = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let parsedDirectory = parseShellSingleQuoted(argument), !parsedDirectory.isEmpty {
                currentDirectory = parsedDirectory
            }
        }

        emitWorkingDirectoryIfNeeded()
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

    private func emitWorkingDirectoryIfNeeded() {
        let hostName = host.address.isEmpty ? "localhost" : host.address
        switch workingDirectoryEventStyle {
        case .none:
            return
        case .osc7OnPrompt:
            emit("\u{001B}]7;file://\(hostName)\(currentDirectory)\u{0007}")
        case .osc7WithSTTerminatorAndPromptNoise:
            emit("\u{001B}]7;file://\(hostName)\(currentDirectory)\u{001B}\\\u{001B}[?2004h\u{001B}]0;root@\(hostName): ~\u{0007}")
        }
    }
}
