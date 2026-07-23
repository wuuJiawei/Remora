import Foundation
import RemoraSSHNative

public enum POSIXCommandBuilder {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func render(_ request: RemoteCommandRequest) throws -> String {
        let command: String
        switch request.executable {
        case .path(let path):
            guard path.hasPrefix("/") else {
                throw RemoteOperationError(
                    category: .command,
                    code: "executable_path_not_absolute",
                    safeDiagnosticMessage: "Remote executable path must be absolute"
                )
            }
            command = ([quote(path)] + request.arguments.map(quote)).joined(separator: " ")
        case .shell(let script):
            guard !script.isEmpty else {
                throw RemoteOperationError(
                    category: .command,
                    code: "shell_script_empty",
                    safeDiagnosticMessage: "Remote shell script is empty"
                )
            }
            command = "/bin/sh -c " + quote(script)
        }

        let environment = try request.environment.keys.sorted().map { key -> String in
            guard isValidEnvironmentKey(key), let value = request.environment[key] else {
                throw RemoteOperationError(
                    category: .command,
                    code: "environment_key_invalid",
                    safeDiagnosticMessage: "Remote command environment contains an invalid key"
                )
            }
            return "\(key)=\(quote(value))"
        }
        let withEnvironment = environment.isEmpty
            ? command
            : "env " + environment.joined(separator: " ") + " " + command
        return request.privilege.wrappingShellCommand(withEnvironment)
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
        else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}

public final class LibSSH2CommandExecutor: RemoteCommandExecutorProtocol, @unchecked Sendable {
    private let transport: LibSSH2Transport
    private let maximumCollectedBytes: Int

    public init(transport: LibSSH2Transport, maximumCollectedBytes: Int = 4 * 1_024 * 1_024) {
        self.transport = transport
        self.maximumCollectedBytes = max(1, maximumCollectedBytes)
    }

    public func start(_ request: RemoteCommandRequest) async throws -> any RemoteCommandExecutionProtocol {
        let command = try POSIXCommandBuilder.render(request)
        let execution = try await transport.openCommand(command, timeout: request.timeout)
        try await execution.start()
        if case .data(let data) = request.standardInput, !data.isEmpty {
            try await execution.writeStandardInput(data)
        }
        try await execution.finishStandardInput()
        return execution
    }

    public func execute(_ request: RemoteCommandRequest) async throws -> RemoteCommandResult {
        let execution = try await start(request)
        let events = await execution.events()
        var stdout = Data()
        var stderr = Data()
        var stdoutTruncated = false
        var stderrTruncated = false
        var exitStatus: Int32?

        do {
            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .standardOutput(let data):
                    append(data, to: &stdout, truncated: &stdoutTruncated)
                case .standardError(let data):
                    append(data, to: &stderr, truncated: &stderrTruncated)
                case .exitStatus(let status):
                    exitStatus = status
                }
            }
        } catch {
            await execution.cancel()
            throw error
        }
        guard let exitStatus else {
            throw RemoteOperationError(
                category: .command,
                code: "command_exit_status_missing",
                safeDiagnosticMessage: "Remote command ended without an exit status"
            )
        }
        return RemoteCommandResult(
            exitStatus: exitStatus,
            standardOutput: stdout,
            standardError: stderr,
            standardOutputWasTruncated: stdoutTruncated,
            standardErrorWasTruncated: stderrTruncated
        )
    }

    private func append(_ data: Data, to output: inout Data, truncated: inout Bool) {
        let remaining = maximumCollectedBytes - output.count
        guard remaining > 0 else {
            truncated = true
            return
        }
        output.append(data.prefix(remaining))
        truncated = truncated || data.count > remaining
    }
}

protocol SFTPCommandExecution: RemoteCommandExecutionProtocol {
    func start() async throws
}

actor NativeCommandExecution: SFTPCommandExecution {
    nonisolated let id = UUID()

    private let handle: NativeSSHChannelHandle
    private let runtime: NativeSSHRuntime
    private let diagnosticLog: NativeSSHDiagnosticLog
    private let timeout: Duration?
    private let stream: AsyncThrowingStream<RemoteCommandEvent, Error>
    private let continuation: AsyncThrowingStream<RemoteCommandEvent, Error>.Continuation
    private var pumpTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var closed = false

    init(
        handle: NativeSSHChannelHandle,
        runtime: NativeSSHRuntime,
        diagnosticLog: NativeSSHDiagnosticLog,
        timeout: Duration?
    ) {
        self.handle = handle
        self.runtime = runtime
        self.diagnosticLog = diagnosticLog
        self.timeout = timeout
        let pair = AsyncThrowingStream<RemoteCommandEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(128)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func start() async throws {
        try await runtime.run(phase: .ready, operation: "command_start", timeout: timeout) {
            try self.handle.start()
        }
        pumpTask = Task { [weak self] in await self?.pump() }
        if let timeout {
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                    await self?.failTimeout()
                } catch {}
            }
        }
    }

    func events() async -> AsyncThrowingStream<RemoteCommandEvent, Error> { stream }

    func writeStandardInput(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let currentOffset = offset
            let result = try await runtime.perform {
                try self.handle.write(data, offset: currentOffset)
            }
            offset += result.1
            if case .wouldBlock(let directions) = result.0 {
                try await runtime.waitForSocket(directions: directions)
            }
        }
    }

    func finishStandardInput() async throws {
        try await runtime.run(phase: .ready, operation: "command_eof", timeout: timeout) {
            try self.handle.sendEOF()
        }
    }

    func cancel() async {
        await close(failure: nil, cancelPump: true)
    }

    private func pump() async {
        do {
            while !closed {
                let stdout = try await read(stream: REMORA_SSH_CHANNEL_STANDARD_OUTPUT)
                let stderr = try await read(stream: REMORA_SSH_CHANNEL_STANDARD_ERROR)
                if !stdout.data.isEmpty { continuation.yield(.standardOutput(stdout.data)) }
                if !stderr.data.isEmpty { continuation.yield(.standardError(stderr.data)) }
                if handle.isEOF {
                    continuation.yield(.exitStatus(handle.exitStatus))
                    await close(failure: nil, cancelPump: false)
                    return
                }
                let directions = stdout.directions.union(stderr.directions)
                if stdout.data.isEmpty, stderr.data.isEmpty {
                    try await runtime.waitForSocket(directions: directions.isEmpty ? .both : directions)
                }
            }
        } catch is CancellationError {
            await close(failure: nil, cancelPump: false)
        } catch {
            await close(failure: error, cancelPump: false)
        }
    }

    private func read(
        stream: remora_ssh_channel_stream
    ) async throws -> (data: Data, directions: NativeSocketDirections) {
        let result = try await runtime.perform {
            try self.handle.read(stream: stream, maximumBytes: 32 * 1_024)
        }
        switch result.0 {
        case .complete: return (result.1, [])
        case .wouldBlock(let directions): return (result.1, directions)
        }
    }

    private func failTimeout() async {
        await close(failure: RemoteOperationError(
            category: .command,
            code: "command_timeout",
            safeDiagnosticMessage: "Remote command timed out"
        ), cancelPump: true)
    }

    private func close(failure: Error?, cancelPump: Bool) async {
        guard !closed else { return }
        closed = true
        if cancelPump { pumpTask?.cancel() }
        timeoutTask?.cancel()
        do {
            try await runtime.run(phase: .closing, operation: "command_close", allowClosing: true) {
                try self.handle.close()
            }
        } catch {
            diagnosticLog.emit(phase: .failed, operation: "command_close", message: "channelID=\(id.uuidString) close failed")
        }
        await runtime.destroyChannel(handle)
        if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
    }
}
