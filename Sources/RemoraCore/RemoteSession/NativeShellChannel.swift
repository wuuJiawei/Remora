import Foundation
import RemoraSSHNative

public actor NativeShellChannel: RemoteShellChannelProtocol {
    public nonisolated let id: UUID

    private enum State {
        case allocated
        case running
        case closing
        case closed
    }

    private let handle: NativeSSHChannelHandle
    private let runtime: NativeSSHRuntime
    private let diagnosticLog: NativeSSHDiagnosticLog
    private let stream: AsyncThrowingStream<RemoteShellEvent, Error>
    private let continuation: AsyncThrowingStream<RemoteShellEvent, Error>.Continuation
    private let writeLock = NativeSSHAsyncLock()
    private let resizeLock = NativeSSHAsyncLock()

    private var state: State = .allocated
    private var outputTask: Task<Void, Never>?
    private var streamFinished = false

    init(
        id: UUID = UUID(),
        handle: NativeSSHChannelHandle,
        runtime: NativeSSHRuntime,
        diagnosticLog: NativeSSHDiagnosticLog
    ) {
        self.id = id
        self.handle = handle
        self.runtime = runtime
        self.diagnosticLog = diagnosticLog
        let pair = AsyncThrowingStream<RemoteShellEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(18)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    deinit {
        outputTask?.cancel()
        continuation.finish()
        runtime.scheduleDestroyChannel(handle)
    }

    public func start() async throws {
        guard state == .allocated else {
            if state == .running { return }
            throw channelClosedError()
        }

        diagnosticLog.emit(
            phase: .openingShell,
            operation: "shell_start",
            message: "channelID=\(id.uuidString) starting"
        )
        do {
            try await runtime.run(phase: .openingShell, operation: "shell_start") {
                try self.handle.start()
            }
            state = .running
            outputTask = Task { [weak self] in
                await self?.pumpOutput()
            }
        } catch {
            state = .closed
            finishStream(throwing: error)
            await runtime.destroyChannel(handle)
            throw error
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        await writeLock.acquire()
        do {
            try Task.checkCancellation()
            guard state == .running else { throw channelClosedError() }

            var offset = 0
            while offset < data.count {
                let currentOffset = offset
                let result = try await runtime.perform {
                    try self.handle.write(data, offset: currentOffset)
                }
                offset += result.1

                if case .wouldBlock(let directions) = result.0 {
                    try await runtime.waitForSocket(directions: directions)
                } else if result.1 == 0, offset < data.count {
                    throw RemoteOperationError(
                        category: .channel,
                        code: "shell_write_stalled",
                        safeDiagnosticMessage: "SSH channel write made no progress"
                    )
                }
            }
            await writeLock.release()
        } catch {
            await writeLock.release()
            throw error
        }
    }

    public func resize(_ size: PTYSize) async throws {
        guard size.columns > 0, size.rows > 0 else {
            throw RemoteOperationError(
                category: .channel,
                code: "invalid_pty_size",
                safeDiagnosticMessage: "SSH PTY size must be positive"
            )
        }

        await resizeLock.acquire()
        do {
            guard state == .running else { throw channelClosedError() }
            try await runtime.run(phase: .ready, operation: "shell_resize") {
                try self.handle.resize(size)
            }
            await resizeLock.release()
        } catch {
            await resizeLock.release()
            throw error
        }
    }

    public func events() async -> AsyncThrowingStream<RemoteShellEvent, Error> {
        stream
    }

    public func close() async {
        guard state != .closing, state != .closed else { return }
        state = .closing
        outputTask?.cancel()
        outputTask = nil

        diagnosticLog.emit(
            phase: .closing,
            operation: "shell_close",
            message: "channelID=\(id.uuidString) closing"
        )
        do {
            try await runtime.run(
                phase: .closing,
                operation: "shell_close",
                allowClosing: true
            ) {
                try self.handle.close()
            }
        } catch {
            diagnosticLog.emit(
                phase: .failed,
                operation: "shell_close",
                backendCode: (error as? RemoteOperationError)?.backendCode,
                message: "channelID=\(id.uuidString) close failed"
            )
        }
        await runtime.destroyChannel(handle)
        state = .closed
        finishStream(throwing: nil)
    }

    private func pumpOutput() async {
        do {
            while state == .running {
                try Task.checkCancellation()
                let stdout = try await read(stream: REMORA_SSH_CHANNEL_STANDARD_OUTPUT)
                let stderr = try await read(stream: REMORA_SSH_CHANNEL_STANDARD_ERROR)

                if !stdout.data.isEmpty {
                    try yield(.standardOutput(stdout.data))
                }
                if !stderr.data.isEmpty {
                    try yield(.standardError(stderr.data))
                }

                let reachedEOF = try await runtime.perform {
                    self.handle.isEOF
                }
                if reachedEOF {
                    let exitStatus = try await runtime.perform {
                        self.handle.exitStatus
                    }
                    try yield(.exitStatus(exitStatus))
                    try yield(.endOfFile)
                    finishStream(throwing: nil)
                    await closeAfterEOF()
                    return
                }

                if stdout.data.isEmpty, stderr.data.isEmpty {
                    let directions = stdout.directions.union(stderr.directions)
                    try await runtime.waitForSocket(
                        directions: directions.isEmpty ? .inbound : directions
                    )
                } else {
                    await Task.yield()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if state == .running {
                state = .closed
                finishStream(throwing: error)
                diagnosticLog.emit(
                    phase: .failed,
                    operation: "shell_output",
                    backendCode: (error as? RemoteOperationError)?.backendCode,
                    message: "channelID=\(id.uuidString) code=\((error as? RemoteOperationError)?.code ?? "output_failed")"
                )
                await runtime.destroyChannel(handle)
            }
        }
    }

    private func read(
        stream: remora_ssh_channel_stream
    ) async throws -> (data: Data, directions: NativeSocketDirections) {
        try await runtime.perform {
            let result = try self.handle.read(stream: stream, maximumBytes: 16 * 1_024)
            switch result.0 {
            case .complete:
                return (result.1, [])
            case .wouldBlock(let directions):
                return (result.1, directions)
            }
        }
    }

    private func closeAfterEOF() async {
        guard state == .running else { return }
        state = .closing
        _ = try? await runtime.run(
            phase: .closing,
            operation: "shell_close_after_eof",
            allowClosing: true
        ) {
            try self.handle.close()
        }
        await runtime.destroyChannel(handle)
        state = .closed
    }

    private func yield(_ event: RemoteShellEvent) throws {
        switch continuation.yield(event) {
        case .enqueued:
            return
        case .dropped:
            throw RemoteOperationError(
                category: .channel,
                code: "shell_output_overflow",
                safeDiagnosticMessage: "SSH shell output exceeded its bounded buffer"
            )
        case .terminated:
            throw channelClosedError()
        @unknown default:
            throw channelClosedError()
        }
    }

    private func finishStream(throwing error: Error?) {
        guard !streamFinished else { return }
        streamFinished = true
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func channelClosedError() -> RemoteOperationError {
        RemoteOperationError(
            category: .channel,
            code: "channel_closed",
            safeDiagnosticMessage: "Native SSH shell channel is closed"
        )
    }
}

private actor NativeSSHAsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            locked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
