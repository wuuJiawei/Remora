import Foundation
import RemoraSSHNative

enum NativeSSHContextError: Error, Equatable {
    case creationFailed(code: UInt32, backendCode: Int32, message: String)
    case closed
}

final class NativeSSHContext {
    static let expectedABIVersion: UInt32 = 1
    static var nativeABIVersion: UInt32 { remora_ssh_native_abi_version() }

    private var handle: OpaquePointer?

    init() throws {
        var newHandle: OpaquePointer?
        var nativeError = remora_ssh_error()
        let result = remora_ssh_context_create(&newHandle, &nativeError)
        guard result == REMORA_SSH_ERROR_NONE, let newHandle else {
            throw NativeSSHContextError.creationFailed(
                code: result.rawValue,
                backendCode: nativeError.backend_code,
                message: String(cString: remora_ssh_error_message(&nativeError))
            )
        }
        handle = newHandle
    }

    deinit {
        close()
    }

    var isOpen: Bool {
        guard let handle else { return false }
        return remora_ssh_context_is_valid(handle)
    }

    func close() {
        remora_ssh_context_destroy(&handle)
    }

    func requireOpen() throws {
        guard let handle, remora_ssh_context_is_valid(handle) else {
            throw NativeSSHContextError.closed
        }
    }
}
