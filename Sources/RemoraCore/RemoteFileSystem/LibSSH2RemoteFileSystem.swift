import Foundation

public actor LibSSH2RemoteFileSystem: RemoteFileSystemProtocol {
    public nonisolated let id = UUID()

    private static let transferChunkSize = 64 * 1_024
    private static let maximumNameBytes = 64 * 1_024
    private static let maximumSymbolicLinkBytes = 64 * 1_024
    private static let directoryMode: UInt32 = 0o755
    private static let fileMode: UInt32 = 0o644

    private let runtime: NativeSSHRuntime
    private let sessionHandle: NativeSFTPSessionHandle
    private let onClose: @Sendable (UUID) async -> Void
    private var fileHandles: [UUID: LibSSH2RemoteFileHandle] = [:]
    private var closed = false

    init(
        runtime: NativeSSHRuntime,
        sessionHandle: NativeSFTPSessionHandle,
        onClose: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.sessionHandle = sessionHandle
        self.onClose = onClose
    }

    public func capabilities() -> RemoteFileSystemCapabilities {
        RemoteFileSystemCapabilities(
            supportsSymbolicLinks: true,
            supportsAtomicRename: false,
            supportsAttributeUpdates: true
        )
    }

    public func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        try ensureOpen(path: path)
        let handle = try await openNativeDirectory(path: path)
        do {
            var entries: [RemoteFileEntry] = []
            while true {
                let result = try await runtime.runResult(
                    phase: .ready,
                    operation: "sftp_readdir"
                ) {
                    let result = try handle.readDirectory(maximumNameBytes: Self.maximumNameBytes)
                    return (result.0, (result.1, result.2))
                }
                if result.1 { break }
                guard let entry = result.0, entry.name != ".", entry.name != ".." else { continue }
                let childPath = Self.join(parent: path, name: entry.name)
                entries.append(Self.fileEntry(path: childPath, entry: entry))
            }
            await closeNativeHandle(handle, operation: "sftp_closedir")
            return entries
        } catch {
            await closeNativeHandle(handle, operation: "sftp_closedir_after_error")
            throw error
        }
    }

    public func attributes(
        path: String,
        followSymbolicLinks: Bool
    ) async throws -> RemoteFileAttributes {
        try ensureOpen(path: path)
        let attributes = try await runtime.runResult(
            phase: .ready,
            operation: followSymbolicLinks ? "sftp_stat" : "sftp_lstat"
        ) {
            let result = try self.sessionHandle.attributes(
                path: path,
                followSymbolicLinks: followSymbolicLinks
            )
            return (result.0, result.1)
        }
        guard let attributes else {
            throw RemoteFileSystemOperationError(status: .malformedResponse, path: path)
        }
        return Self.fileAttributes(attributes)
    }

    public func openFile(
        path: String,
        options: RemoteFileOpenOptions,
        attributes: RemoteFileAttributes?
    ) async throws -> any RemoteFileHandleProtocol {
        try ensureOpen(path: path)
        guard !options.isEmpty else {
            throw RemoteFileSystemOperationError(status: .invalidPath, path: path)
        }
        let mode = attributes?.permissions.map(UInt32.init) ?? Self.fileMode
        let nativeHandle = try await runtime.runResult(
            phase: .ready,
            operation: "sftp_open_file"
        ) {
            let result = try self.sessionHandle.openFile(path: path, options: options, mode: mode)
            return (result.0, result.1)
        }
        guard let nativeHandle else {
            throw RemoteFileSystemOperationError(status: .malformedResponse, path: path)
        }
        let fileHandle = LibSSH2RemoteFileHandle(
            nativeHandle: nativeHandle,
            runtime: runtime,
            maximumChunkSize: Self.transferChunkSize
        ) { [weak self] handleID in
            await self?.removeFileHandle(id: handleID)
        }
        fileHandles[fileHandle.id] = fileHandle
        return fileHandle
    }

    public func createDirectory(path: String, attributes: RemoteFileAttributes?) async throws {
        try ensureOpen(path: path)
        let mode = attributes?.permissions.map(UInt32.init) ?? Self.directoryMode
        try await runtime.run(phase: .ready, operation: "sftp_mkdir") {
            try self.sessionHandle.createDirectory(path: path, mode: mode)
        }
    }

    public func removeFile(path: String) async throws {
        try ensureOpen(path: path)
        try await runtime.run(phase: .ready, operation: "sftp_remove_file") {
            try self.sessionHandle.removeFile(path: path)
        }
    }

    public func removeDirectory(path: String) async throws {
        try ensureOpen(path: path)
        try await runtime.run(phase: .ready, operation: "sftp_remove_directory") {
            try self.sessionHandle.removeDirectory(path: path)
        }
    }

    public func rename(from sourcePath: String, to destinationPath: String, overwrite: Bool) async throws {
        try ensureOpen(path: sourcePath)
        try await runtime.run(phase: .ready, operation: "sftp_rename") {
            try self.sessionHandle.rename(
                from: sourcePath,
                to: destinationPath,
                overwrite: overwrite
            )
        }
    }

    public func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try ensureOpen(path: path)
        let nativeAttributes = NativeSFTPAttributes(attributes: attributes)
        try await runtime.run(phase: .ready, operation: "sftp_set_attributes") {
            try self.sessionHandle.setAttributes(path: path, attributes: nativeAttributes)
        }
    }

    public func readSymbolicLink(path: String) async throws -> String {
        try ensureOpen(path: path)
        let target = try await runtime.runResult(
            phase: .ready,
            operation: "sftp_readlink"
        ) {
            let result = try self.sessionHandle.readSymbolicLink(
                path: path,
                maximumBytes: Self.maximumSymbolicLinkBytes
            )
            return (result.0, result.1)
        }
        guard let target else {
            throw RemoteFileSystemOperationError(status: .malformedResponse, path: path)
        }
        return target
    }

    public func createSymbolicLink(path: String, target: String) async throws {
        try ensureOpen(path: path)
        try await runtime.run(phase: .ready, operation: "sftp_symlink") {
            try self.sessionHandle.createSymbolicLink(path: path, target: target)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        let handles = Array(fileHandles.values)
        fileHandles.removeAll(keepingCapacity: false)
        for handle in handles {
            await handle.close()
        }
        _ = try? await runtime.run(
            phase: .closing,
            operation: "sftp_shutdown",
            allowClosing: true
        ) {
            try self.sessionHandle.close()
        }
        await onClose(id)
    }

    private func openNativeDirectory(path: String) async throws -> NativeSFTPFileHandle {
        let handle = try await runtime.runResult(phase: .ready, operation: "sftp_opendir") {
            let result = try self.sessionHandle.openDirectory(path: path)
            return (result.0, result.1)
        }
        guard let handle else {
            throw RemoteFileSystemOperationError(status: .malformedResponse, path: path)
        }
        return handle
    }

    private func closeNativeHandle(_ handle: NativeSFTPFileHandle, operation: String) async {
        _ = try? await runtime.run(phase: .closing, operation: operation, allowClosing: true) {
            try handle.close()
        }
    }

    private func removeFileHandle(id: UUID) {
        fileHandles.removeValue(forKey: id)
    }

    private func ensureOpen(path: String) throws {
        guard !closed else {
            throw RemoteFileSystemOperationError(status: .connectionLost, path: path)
        }
    }

    private static func fileEntry(path: String, entry: NativeSFTPDirectoryEntry) -> RemoteFileEntry {
        let attributes = fileAttributes(entry.attributes)
        return RemoteFileEntry(
            name: entry.name,
            path: path,
            size: attributes.size,
            permissions: attributes.permissions,
            owner: attributes.owner,
            group: attributes.group,
            isDirectory: attributes.isDirectory,
            isSymbolicLink: attributes.isSymbolicLink,
            modifiedAt: attributes.modifiedAt
        )
    }

    private static func fileAttributes(_ attributes: NativeSFTPAttributes) -> RemoteFileAttributes {
        let hasSize = attributes.flags & 1 != 0
        let hasOwner = attributes.flags & 2 != 0
        let hasPermissions = attributes.flags & 4 != 0
        let hasTimes = attributes.flags & 8 != 0
        let mode = attributes.permissions
        return RemoteFileAttributes(
            permissions: hasPermissions ? UInt16(truncatingIfNeeded: mode & 0o7777) : nil,
            owner: hasOwner ? String(attributes.uid) : nil,
            group: hasOwner ? String(attributes.gid) : nil,
            size: hasSize ? Int64(clamping: attributes.size) : 0,
            modifiedAt: hasTimes
                ? Date(timeIntervalSince1970: TimeInterval(attributes.modificationTime))
                : Date(timeIntervalSince1970: 0),
            isDirectory: hasPermissions && (mode & 0o170000) == 0o040000,
            isSymbolicLink: hasPermissions && (mode & 0o170000) == 0o120000
        )
    }

    private static func join(parent: String, name: String) -> String {
        if parent == "/" { return "/\(name)" }
        return parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }
}

private actor LibSSH2RemoteFileHandle: RemoteFileHandleProtocol {
    nonisolated let id = UUID()

    private let nativeHandle: NativeSFTPFileHandle
    private let runtime: NativeSSHRuntime
    private let maximumChunkSize: Int
    private let onClose: @Sendable (UUID) async -> Void
    private var closed = false

    init(
        nativeHandle: NativeSFTPFileHandle,
        runtime: NativeSSHRuntime,
        maximumChunkSize: Int,
        onClose: @escaping @Sendable (UUID) async -> Void
    ) {
        self.nativeHandle = nativeHandle
        self.runtime = runtime
        self.maximumChunkSize = maximumChunkSize
        self.onClose = onClose
    }

    func read(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw closedError() }
        let boundedBytes = min(max(1, maximumBytes), maximumChunkSize)
        let result = try await runtime.runResult(phase: .ready, operation: "sftp_read") {
            let result = try self.nativeHandle.read(maximumBytes: boundedBytes)
            return (result.0, (result.1, result.2))
        }
        return result.0
    }

    func write(_ data: Data) async throws -> Int {
        guard !closed else { throw closedError() }
        guard !data.isEmpty else { return 0 }
        let chunk = Data(data.prefix(maximumChunkSize))
        return try await runtime.runResult(phase: .ready, operation: "sftp_write") {
            try self.nativeHandle.write(chunk)
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        _ = try? await runtime.run(
            phase: .closing,
            operation: "sftp_close_handle",
            allowClosing: true
        ) {
            try self.nativeHandle.close()
        }
        await onClose(id)
    }

    private func closedError() -> RemoteFileSystemOperationError {
        RemoteFileSystemOperationError(status: .connectionLost)
    }
}
