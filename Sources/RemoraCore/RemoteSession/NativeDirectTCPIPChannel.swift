import Foundation
import RemoraSSHNative

public actor NativeDirectTCPIPChannel: RemoteForwardChannelProtocol {
    public nonisolated let id = UUID()

    private let handle: NativeSSHChannelHandle
    private let runtime: NativeSSHRuntime
    private let diagnosticLog: NativeSSHDiagnosticLog
    private var closed = false
    private var writingFinished = false

    init(
        handle: NativeSSHChannelHandle,
        runtime: NativeSSHRuntime,
        diagnosticLog: NativeSSHDiagnosticLog
    ) {
        self.handle = handle
        self.runtime = runtime
        self.diagnosticLog = diagnosticLog
    }

    public func read(maximumBytes: Int) async throws -> Data? {
        guard !closed else { throw closedError() }
        guard maximumBytes > 0 else {
            throw RemoteOperationError(
                category: .channel,
                code: "forward_read_size_invalid",
                safeDiagnosticMessage: "Forwarding channel read size must be positive"
            )
        }

        while true {
            try Task.checkCancellation()
            let result = try await runtime.perform {
                try self.handle.read(
                    stream: REMORA_SSH_CHANNEL_STANDARD_OUTPUT,
                    maximumBytes: maximumBytes
                )
            }
            if !result.1.isEmpty { return result.1 }
            let isEOF = try await runtime.perform { self.handle.isEOF }
            if isEOF { return nil }
            switch result.0 {
            case .complete:
                try await runtime.waitForSocket(directions: .inbound)
            case .wouldBlock(let directions):
                try await runtime.waitForSocket(directions: directions)
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard !closed else { throw closedError() }
        guard !writingFinished else {
            throw RemoteOperationError(
                category: .channel,
                code: "forward_write_after_eof",
                safeDiagnosticMessage: "Forwarding channel input is already closed"
            )
        }

        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let currentOffset = offset
            let result = try await runtime.perform {
                try self.handle.write(data, offset: currentOffset)
            }
            offset += result.1
            if result.1 == 0 {
                try await runtime.waitForSocket(directions: .outbound)
            } else if case .wouldBlock(let directions) = result.0 {
                try await runtime.waitForSocket(directions: directions)
            }
        }
    }

    public func finishWriting() async throws {
        guard !closed, !writingFinished else { return }
        try await runtime.run(phase: .ready, operation: "direct_tcpip_eof") {
            try self.handle.sendEOF()
        }
        writingFinished = true
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        do {
            try await runtime.run(
                phase: .closing,
                operation: "direct_tcpip_close",
                allowClosing: true
            ) {
                try self.handle.close()
            }
        } catch {
            diagnosticLog.emit(
                phase: .failed,
                operation: "direct_tcpip_close",
                message: "channelID=\(id.uuidString) close failed"
            )
        }
        await runtime.destroyChannel(handle)
    }

    private func closedError() -> RemoteOperationError {
        RemoteOperationError(
            category: .channel,
            code: "forward_channel_closed",
            safeDiagnosticMessage: "Remote forwarding channel is closed"
        )
    }
}
