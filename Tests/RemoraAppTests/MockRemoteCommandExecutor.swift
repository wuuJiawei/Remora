import Foundation
import RemoraCore

actor MockRemoteCommandExecutor: RemoteCommandExecutorProtocol {
    typealias ExecuteHandler = @Sendable (RemoteCommandRequest) async throws -> RemoteCommandResult
    typealias StreamHandler = @Sendable (RemoteCommandRequest) async throws -> AsyncThrowingStream<RemoteCommandEvent, Error>

    private let executeHandler: ExecuteHandler
    private let streamHandler: StreamHandler?

    init(
        execute: @escaping ExecuteHandler,
        stream: StreamHandler? = nil
    ) {
        executeHandler = execute
        streamHandler = stream
    }

    init(responses: [String: Result<String, Error>]) {
        executeHandler = { request in
            let command = try Self.shellCommand(from: request)
            guard let response = responses[command] else {
                throw MockRemoteCommandError.missingResponse(command)
            }
            return RemoteCommandResult(
                exitStatus: 0,
                standardOutput: Data(try response.get().utf8),
                standardError: Data()
            )
        }
        streamHandler = nil
    }

    init(fileSystem: MockRemoteFileSystem) {
        executeHandler = { request in
            let command = try Self.shellCommand(from: request)
            if let output = try await fileSystem.executeArchiveCommand(command) {
                return RemoteCommandResult(
                    exitStatus: 0,
                    standardOutput: Data(output.utf8),
                    standardError: Data()
                )
            }
            let tail = try Self.parseTailRequest(command)
            let data = try await fileSystem.fileData(at: tail.path)
            return RemoteCommandResult(
                exitStatus: 0,
                standardOutput: Data(Self.tailText(data: data, lineCount: tail.lineCount).utf8),
                standardError: Data()
            )
        }
        streamHandler = { request in
            let tail = try Self.parseTailRequest(try Self.shellCommand(from: request))
            guard tail.follow else {
                let data = try await fileSystem.fileData(at: tail.path)
                let text = Self.tailText(data: data, lineCount: tail.lineCount)
                return Self.finishedStream(output: text)
            }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var previous = ""
                        while !Task.isCancelled {
                            let data = try await fileSystem.fileData(at: tail.path)
                            let current = Self.tailText(data: data, lineCount: tail.lineCount)
                            if current != previous {
                                let delta = current.hasPrefix(previous)
                                    ? String(current.dropFirst(previous.count))
                                    : current
                                if !delta.isEmpty {
                                    continuation.yield(.standardOutput(Data(delta.utf8)))
                                }
                                previous = current
                            }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    func start(_ request: RemoteCommandRequest) async throws -> any RemoteCommandExecutionProtocol {
        if let streamHandler {
            return MockRemoteCommandExecution(stream: try await streamHandler(request))
        }
        let result = try await executeHandler(request)
        return MockRemoteCommandExecution(
            stream: AsyncThrowingStream { continuation in
                if !result.standardOutput.isEmpty {
                    continuation.yield(.standardOutput(result.standardOutput))
                }
                if !result.standardError.isEmpty {
                    continuation.yield(.standardError(result.standardError))
                }
                continuation.yield(.exitStatus(result.exitStatus))
                continuation.finish()
            }
        )
    }

    func execute(_ request: RemoteCommandRequest) async throws -> RemoteCommandResult {
        try await executeHandler(request)
    }

    private static func shellCommand(from request: RemoteCommandRequest) throws -> String {
        guard case .shell(let command) = request.executable else {
            throw MockRemoteCommandError.unsupportedExecutable
        }
        return command
    }

    private static func parseTailRequest(
        _ command: String
    ) throws -> (lineCount: Int, follow: Bool, path: String) {
        guard let tailRange = command.range(of: "tail -n ") else {
            throw MockRemoteCommandError.unsupportedCommand(command)
        }
        let suffix = command[tailRange.upperBound...]
        guard let separator = suffix.firstIndex(of: " "),
              let lineCount = Int(suffix[..<separator])
        else {
            throw MockRemoteCommandError.unsupportedCommand(command)
        }
        guard let firstQuote = command.lastIndex(of: "'"),
              let openingQuote = command[..<firstQuote].lastIndex(of: "'")
        else {
            throw MockRemoteCommandError.unsupportedCommand(command)
        }
        let path = String(command[command.index(after: openingQuote) ..< firstQuote])
            .replacingOccurrences(of: "'\\''", with: "'")
        return (lineCount, command.contains(" -f "), path)
    }

    private static func tailText(data: Data, lineCount: Int) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lineCount)
            .joined(separator: "\n")
    }

    private static func finishedStream(output: String) -> AsyncThrowingStream<RemoteCommandEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.standardOutput(Data(output.utf8)))
            continuation.yield(.exitStatus(0))
            continuation.finish()
        }
    }
}

private actor MockRemoteCommandExecution: RemoteCommandExecutionProtocol {
    nonisolated let id = UUID()
    private let stream: AsyncThrowingStream<RemoteCommandEvent, Error>

    init(stream: AsyncThrowingStream<RemoteCommandEvent, Error>) {
        self.stream = stream
    }

    func events() -> AsyncThrowingStream<RemoteCommandEvent, Error> { stream }
    func writeStandardInput(_ data: Data) { _ = data }
    func finishStandardInput() { }
    func cancel() { }
}

private enum MockRemoteCommandError: Error {
    case missingResponse(String)
    case unsupportedExecutable
    case unsupportedCommand(String)
}
