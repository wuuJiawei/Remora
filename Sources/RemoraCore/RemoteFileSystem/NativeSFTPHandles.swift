import Foundation
import RemoraSSHNative

struct NativeSFTPAttributes: Sendable {
    let flags: UInt32
    let size: UInt64
    let uid: UInt32
    let gid: UInt32
    let permissions: UInt32
    let accessTime: UInt32
    let modificationTime: UInt32

    init(native: remora_ssh_sftp_attributes) {
        flags = native.flags
        size = native.size
        uid = native.uid
        gid = native.gid
        permissions = native.permissions
        accessTime = native.access_time
        modificationTime = native.modification_time
    }

    init(attributes: RemoteFileAttributes) {
        var flags: UInt32 = 0
        var permissions: UInt32 = 0
        if let value = attributes.permissions {
            flags |= REMORA_SFTP_ATTRIBUTE_PERMISSIONS
            permissions = UInt32(value)
        }
        let uid = attributes.owner.flatMap(UInt32.init)
        let gid = attributes.group.flatMap(UInt32.init)
        if uid != nil, gid != nil {
            flags |= REMORA_SFTP_ATTRIBUTE_UID_GID
        }
        flags |= REMORA_SFTP_ATTRIBUTE_TIMES
        self.flags = flags
        self.size = 0
        self.uid = uid ?? 0
        self.gid = gid ?? 0
        self.permissions = permissions
        self.accessTime = UInt32(clamping: Int64(attributes.modifiedAt.timeIntervalSince1970))
        self.modificationTime = UInt32(clamping: Int64(attributes.modifiedAt.timeIntervalSince1970))
    }

    var native: remora_ssh_sftp_attributes {
        var value = remora_ssh_sftp_attributes()
        value.flags = flags
        value.size = size
        value.uid = uid
        value.gid = gid
        value.permissions = permissions
        value.access_time = accessTime
        value.modification_time = modificationTime
        return value
    }
}

struct NativeSFTPDirectoryEntry: Sendable {
    let name: String
    let attributes: NativeSFTPAttributes
}

final class NativeSFTPSessionHandle: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let context: NativeSSHContext

    init(handle: OpaquePointer, context: NativeSSHContext) {
        self.handle = handle
        self.context = context
    }

    deinit {
        remora_ssh_sftp_destroy(&handle)
    }

    func start() throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var error = remora_ssh_error()
        return try status(remora_ssh_sftp_start(handle, &error), error: &error, path: nil)
    }

    func openFile(
        path: String,
        options: RemoteFileOpenOptions,
        mode: UInt32
    ) throws -> (NativeSSHCallStatus, NativeSFTPFileHandle?) {
        let handle = try requiredStartedHandle()
        try Self.validatePath(path)
        var fileHandle: OpaquePointer?
        var error = remora_ssh_error()
        let result = path.withCString {
            remora_ssh_sftp_open_file(
                handle,
                $0,
                UInt32(options.rawValue),
                mode,
                &fileHandle,
                &error
            )
        }
        let callStatus = try status(result, error: &error, path: path)
        return (
            callStatus,
            fileHandle.map { NativeSFTPFileHandle(handle: $0, session: self, directory: false) }
        )
    }

    func openDirectory(path: String) throws -> (NativeSSHCallStatus, NativeSFTPFileHandle?) {
        let handle = try requiredStartedHandle()
        try Self.validatePath(path)
        var directoryHandle: OpaquePointer?
        var error = remora_ssh_error()
        let result = path.withCString {
            remora_ssh_sftp_open_directory(handle, $0, &directoryHandle, &error)
        }
        let callStatus = try status(result, error: &error, path: path)
        return (
            callStatus,
            directoryHandle.map { NativeSFTPFileHandle(handle: $0, session: self, directory: true) }
        )
    }

    func attributes(path: String, followSymbolicLinks: Bool) throws -> (NativeSSHCallStatus, NativeSFTPAttributes?) {
        let handle = try requiredStartedHandle()
        try Self.validatePath(path)
        var nativeAttributes = remora_ssh_sftp_attributes()
        var error = remora_ssh_error()
        let result = path.withCString {
            remora_ssh_sftp_stat(handle, $0, followSymbolicLinks, &nativeAttributes, &error)
        }
        let callStatus = try status(result, error: &error, path: path)
        return (callStatus, callStatus.isComplete ? NativeSFTPAttributes(native: nativeAttributes) : nil)
    }

    func setAttributes(path: String, attributes: NativeSFTPAttributes) throws -> NativeSSHCallStatus {
        let handle = try requiredStartedHandle()
        try Self.validatePath(path)
        var nativeAttributes = attributes.native
        var error = remora_ssh_error()
        let result = path.withCString {
            remora_ssh_sftp_set_attributes(handle, $0, &nativeAttributes, &error)
        }
        return try status(result, error: &error, path: path)
    }

    func createDirectory(path: String, mode: UInt32) throws -> NativeSSHCallStatus {
        try pathOperation(path: path) { handle, path, error in
            remora_ssh_sftp_create_directory(handle, path, mode, error)
        }
    }

    func removeFile(path: String) throws -> NativeSSHCallStatus {
        try pathOperation(path: path, remora_ssh_sftp_remove_file)
    }

    func removeDirectory(path: String) throws -> NativeSSHCallStatus {
        try pathOperation(path: path, remora_ssh_sftp_remove_directory)
    }

    func rename(from source: String, to destination: String, overwrite: Bool) throws -> NativeSSHCallStatus {
        let handle = try requiredStartedHandle()
        try Self.validatePath(source)
        try Self.validatePath(destination)
        var error = remora_ssh_error()
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                remora_ssh_sftp_rename(
                    handle,
                    sourcePointer,
                    destinationPointer,
                    overwrite,
                    &error
                )
            }
        }
        return try status(result, error: &error, path: source)
    }

    func readSymbolicLink(path: String, maximumBytes: Int) throws -> (NativeSSHCallStatus, String?) {
        let handle = try requiredStartedHandle()
        try Self.validatePath(path)
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        var length = 0
        var error = remora_ssh_error()
        let result = path.withCString {
            remora_ssh_sftp_read_symbolic_link(
                handle,
                $0,
                &buffer,
                buffer.count,
                &length,
                &error
            )
        }
        let callStatus = try status(result, error: &error, path: path)
        guard callStatus.isComplete else { return (callStatus, nil) }
        guard let value = String(bytes: buffer.prefix(length), encoding: .utf8) else {
            throw RemoteFileSystemOperationError(status: .malformedResponse, path: path)
        }
        return (callStatus, value)
    }

    func createSymbolicLink(path: String, target: String) throws -> NativeSSHCallStatus {
        let handle = try requiredStartedHandle()
        try Self.validatePath(path)
        try Self.validatePath(target)
        var error = remora_ssh_error()
        let result = path.withCString { pathPointer in
            target.withCString { targetPointer in
                remora_ssh_sftp_create_symbolic_link(handle, pathPointer, targetPointer, &error)
            }
        }
        return try status(result, error: &error, path: path)
    }

    func close() throws -> NativeSSHCallStatus {
        guard let handle else { return .complete }
        var error = remora_ssh_error()
        let callStatus = try status(remora_ssh_sftp_shutdown(handle, &error), error: &error, path: nil)
        if callStatus.isComplete {
            remora_ssh_sftp_destroy(&self.handle)
        }
        return callStatus
    }

    func status(
        _ result: remora_ssh_error_code,
        error: inout remora_ssh_error,
        path: String?
    ) throws -> NativeSSHCallStatus {
        switch result {
        case REMORA_SSH_ERROR_NONE:
            return .complete
        case REMORA_SSH_ERROR_WOULD_BLOCK:
            return .wouldBlock(context.blockDirections())
        case REMORA_SSH_ERROR_SFTP_FAILURE:
            throw RemoteFileSystemOperationError(
                status: Self.fileSystemStatus(error.backend_code),
                path: path,
                backendCode: Int(error.backend_code)
            )
        default:
            throw RemoteOperationError(
                category: .fileSystem,
                code: "native_sftp_failed",
                safeDiagnosticMessage: String(cString: remora_ssh_error_message(&error)),
                backendCode: Int(error.backend_code)
            )
        }
    }

    private func pathOperation(
        path: String,
        _ operation: (OpaquePointer, UnsafePointer<CChar>, UnsafeMutablePointer<remora_ssh_error>) -> remora_ssh_error_code
    ) throws -> NativeSSHCallStatus {
        let handle = try requiredStartedHandle()
        try Self.validatePath(path)
        var error = remora_ssh_error()
        let result = path.withCString { operation(handle, $0, &error) }
        return try status(result, error: &error, path: path)
    }

    private func requiredHandle() throws -> OpaquePointer {
        guard let handle, remora_ssh_sftp_is_valid(handle) else {
            throw RemoteFileSystemOperationError(status: .connectionLost)
        }
        return handle
    }

    private func requiredStartedHandle() throws -> OpaquePointer {
        try requiredHandle()
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.contains("\0") else {
            throw RemoteFileSystemOperationError(status: .invalidPath, path: path)
        }
    }

    private static func fileSystemStatus(_ code: Int32) -> RemoteFileSystemStatus {
        switch code {
        case 2, 10: .notFound
        case 3, 12: .permissionDenied
        case 11: .alreadyExists
        case 5: .malformedResponse
        case 6, 7: .connectionLost
        case 8: .unsupported
        case 20: .invalidPath
        default: .unknown
        }
    }
}

final class NativeSFTPFileHandle: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let session: NativeSFTPSessionHandle
    let directory: Bool

    init(handle: OpaquePointer, session: NativeSFTPSessionHandle, directory: Bool) {
        self.handle = handle
        self.session = session
        self.directory = directory
    }

    deinit {
        remora_ssh_sftp_handle_destroy(&handle)
    }

    func read(maximumBytes: Int) throws -> (NativeSSHCallStatus, Data, Bool) {
        let handle = try requiredHandle()
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        var length = 0
        var eof = false
        var error = remora_ssh_error()
        let result = remora_ssh_sftp_handle_read(
            handle,
            &buffer,
            buffer.count,
            &length,
            &eof,
            &error
        )
        let callStatus = try session.status(result, error: &error, path: nil)
        return (callStatus, Data(buffer.prefix(length)), eof)
    }

    func write(_ data: Data) throws -> (NativeSSHCallStatus, Int) {
        let handle = try requiredHandle()
        var written = 0
        var error = remora_ssh_error()
        let result = data.withUnsafeBytes { bytes in
            remora_ssh_sftp_handle_write(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                &written,
                &error
            )
        }
        return (try session.status(result, error: &error, path: nil), written)
    }

    func readDirectory(maximumNameBytes: Int) throws -> (NativeSSHCallStatus, NativeSFTPDirectoryEntry?, Bool) {
        let handle = try requiredHandle()
        var buffer = [UInt8](repeating: 0, count: maximumNameBytes)
        var length = 0
        var attributes = remora_ssh_sftp_attributes()
        var eof = false
        var error = remora_ssh_error()
        let result = remora_ssh_sftp_handle_read_directory(
            handle,
            &buffer,
            buffer.count,
            &length,
            &attributes,
            &eof,
            &error
        )
        let callStatus = try session.status(result, error: &error, path: nil)
        guard callStatus.isComplete, !eof else { return (callStatus, nil, eof) }
        guard let name = String(bytes: buffer.prefix(length), encoding: .utf8) else {
            throw RemoteFileSystemOperationError(status: .malformedResponse)
        }
        return (
            callStatus,
            NativeSFTPDirectoryEntry(name: name, attributes: NativeSFTPAttributes(native: attributes)),
            false
        )
    }

    func close() throws -> NativeSSHCallStatus {
        guard let handle else { return .complete }
        var error = remora_ssh_error()
        let callStatus = try session.status(
            remora_ssh_sftp_handle_close(handle, &error),
            error: &error,
            path: nil
        )
        if callStatus.isComplete {
            remora_ssh_sftp_handle_destroy(&self.handle)
        }
        return callStatus
    }

    private func requiredHandle() throws -> OpaquePointer {
        guard let handle, remora_ssh_sftp_handle_is_valid(handle) else {
            throw RemoteFileSystemOperationError(status: .connectionLost)
        }
        return handle
    }
}

private extension NativeSSHCallStatus {
    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}
