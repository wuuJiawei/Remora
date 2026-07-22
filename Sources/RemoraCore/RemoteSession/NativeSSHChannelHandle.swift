import Foundation
import RemoraSSHNative

final class NativeSSHChannelHandle: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let context: NativeSSHContext

    init(handle: OpaquePointer, context: NativeSSHContext) {
        self.handle = handle
        self.context = context
    }

    deinit {
        destroy()
    }

    var isOpen: Bool {
        guard let handle else { return false }
        return remora_ssh_channel_is_valid(handle)
    }

    var isEOF: Bool {
        guard let handle else { return true }
        return remora_ssh_channel_is_eof(handle)
    }

    var exitStatus: Int32 {
        guard let handle else { return -1 }
        return remora_ssh_channel_exit_status(handle)
    }

    func start() throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var error = remora_ssh_error()
        let result = remora_ssh_channel_start(handle, &error)
        return try status(result, error: &error, code: "shell_start_failed")
    }

    func read(
        stream: remora_ssh_channel_stream,
        maximumBytes: Int
    ) throws -> (NativeSSHCallStatus, Data) {
        let handle = try requiredHandle()
        let capacity = max(1, maximumBytes)
        var buffer = [UInt8](repeating: 0, count: capacity)
        var length = 0
        var error = remora_ssh_error()
        let result = remora_ssh_channel_read(
            handle,
            stream,
            &buffer,
            buffer.count,
            &length,
            &error
        )
        let callStatus = try status(result, error: &error, code: "shell_read_failed")
        return (callStatus, Data(buffer.prefix(length)))
    }

    func write(_ data: Data, offset: Int) throws -> (NativeSSHCallStatus, Int) {
        let handle = try requiredHandle()
        guard offset >= 0, offset <= data.count else {
            throw RemoteOperationError(
                category: .channel,
                code: "invalid_write_offset",
                safeDiagnosticMessage: "SSH channel write offset is invalid"
            )
        }
        var written = 0
        var error = remora_ssh_error()
        let result = data.withUnsafeBytes { bytes in
            let start = bytes.baseAddress?.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return remora_ssh_channel_write(
                handle,
                start,
                data.count - offset,
                &written,
                &error
            )
        }
        return (try status(result, error: &error, code: "shell_write_failed"), written)
    }

    func resize(_ size: PTYSize) throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var error = remora_ssh_error()
        let result = remora_ssh_channel_resize(
            handle,
            UInt32(clamping: size.columns),
            UInt32(clamping: size.rows),
            &error
        )
        return try status(result, error: &error, code: "shell_resize_failed")
    }

    func close() throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var error = remora_ssh_error()
        let result = remora_ssh_channel_close(handle, &error)
        return try status(result, error: &error, code: "shell_close_failed")
    }

    func destroy() {
        remora_ssh_channel_destroy(&handle)
    }

    private func requiredHandle() throws -> OpaquePointer {
        guard let handle, remora_ssh_channel_is_valid(handle) else {
            throw RemoteOperationError(
                category: .channel,
                code: "channel_closed",
                safeDiagnosticMessage: "Native SSH channel is closed"
            )
        }
        return handle
    }

    private func status(
        _ result: remora_ssh_error_code,
        error: inout remora_ssh_error,
        code: String
    ) throws -> NativeSSHCallStatus {
        switch result {
        case REMORA_SSH_ERROR_NONE:
            return .complete
        case REMORA_SSH_ERROR_WOULD_BLOCK:
            return .wouldBlock(context.blockDirections())
        default:
            throw RemoteOperationError(
                category: .channel,
                code: code,
                safeDiagnosticMessage: String(cString: remora_ssh_error_message(&error)),
                backendCode: Int(error.backend_code)
            )
        }
    }
}
