import Foundation

public actor ExecSFTPRemoteFileSystem: RemoteFileSystem {
    public nonisolated let id = UUID()

    private enum ConnectionState {
        case awaitingVersion
        case ready
        case failed(Error)
        case closed
    }

    private static let transferChunkSize = 64 * 1_024
    private static let maximumCapturedStderrBytes = 64 * 1_024
    private static let fileMode: UInt32 = 0o644
    private static let directoryMode: UInt32 = 0o755

    private let execution: any SFTPCommandExecution
    private let codecConfiguration: SFTPCodec
    private let multiplexer: SFTPRequestMultiplexer
    private let onClose: @Sendable (UUID) async -> Void
    private let versionStream: AsyncThrowingStream<UInt32, Error>
    private let versionContinuation: AsyncThrowingStream<UInt32, Error>.Continuation

    private var decoder: SFTPCodec
    private var state: ConnectionState = .awaitingVersion
    private var serverExtensions: [String: Data] = [:]
    private var standardError = Data()
    private var fileHandles: [UUID: ExecSFTPRemoteFileHandle] = [:]
    private var readerTask: Task<Void, Never>?
    private var didNotifyClose = false

    init(
        execution: any SFTPCommandExecution,
        codec: SFTPCodec = SFTPCodec(),
        maximumOutstandingRequests: Int = 64,
        onClose: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.execution = execution
        codecConfiguration = codec
        decoder = codec
        multiplexer = SFTPRequestMultiplexer(
            maximumOutstandingRequests: maximumOutstandingRequests,
            codec: codec
        )
        self.onClose = onClose
        let pair = AsyncThrowingStream<UInt32, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        versionStream = pair.stream
        versionContinuation = pair.continuation
    }

    static func open(
        transport: LibSSH2Transport,
        serverPath: String,
        onClose: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) async throws -> ExecSFTPRemoteFileSystem {
        let command = "sudo -n -- \(POSIXCommandBuilder.quote(serverPath))"
        let execution = try await transport.openCommand(command, timeout: nil)
        return try await open(execution: execution, onClose: onClose)
    }

    static func open(
        execution: any SFTPCommandExecution,
        codec: SFTPCodec = SFTPCodec(),
        maximumOutstandingRequests: Int = 64,
        onClose: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) async throws -> ExecSFTPRemoteFileSystem {
        let fileSystem = ExecSFTPRemoteFileSystem(
            execution: execution,
            codec: codec,
            maximumOutstandingRequests: maximumOutstandingRequests,
            onClose: onClose
        )
        do {
            try await fileSystem.start()
            return fileSystem
        } catch {
            await fileSystem.close()
            throw error
        }
    }

    public func capabilities() -> RemoteFileSystemCapabilities {
        RemoteFileSystemCapabilities(
            supportsSymbolicLinks: true,
            supportsAtomicRename: serverExtensions["posix-rename@openssh.com"] != nil,
            supportsAttributeUpdates: true
        )
    }

    public func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        try ensureReady(path: path)
        var payload = SFTPDataWriter()
        payload.appendString(path)
        let openResponse = try await request(type: .opendir, payload: payload.data, expecting: [.handle])
        let handle = try codecConfiguration.handle(from: openResponse)

        do {
            var entries: [RemoteFileEntry] = []
            while true {
                var readPayload = SFTPDataWriter()
                readPayload.appendDataString(handle)
                let response = try await request(
                    type: .readdir,
                    payload: readPayload.data,
                    expecting: [.name]
                )
                if response.type == SFTPMessageType.status.rawValue {
                    let status = try codecConfiguration.status(from: response)
                    if status.code == SFTPStatusCode.endOfFile.rawValue { break }
                    throw statusError(status, path: path)
                }
                for entry in try codecConfiguration.names(from: response)
                    where entry.filename != "." && entry.filename != ".."
                {
                    let childPath = Self.join(parent: path, name: entry.filename)
                    entries.append(Self.remoteEntry(path: childPath, entry: entry))
                }
            }
            try await closeHandle(handle, path: path)
            return entries
        } catch {
            try? await closeHandle(handle, path: path)
            throw error
        }
    }

    public func attributes(path: String, followSymbolicLinks: Bool) async throws -> RemoteFileAttributes {
        try ensureReady(path: path)
        var payload = SFTPDataWriter()
        payload.appendString(path)
        let response = try await request(
            type: followSymbolicLinks ? .stat : .lstat,
            payload: payload.data,
            expecting: [.attrs]
        )
        try throwIfStatus(response, path: path)
        return Self.remoteAttributes(try codecConfiguration.attributes(from: response))
    }

    public func openFile(
        path: String,
        options: RemoteFileOpenOptions,
        attributes: RemoteFileAttributes?
    ) async throws -> any RemoteFileHandleProtocol {
        try ensureReady(path: path)
        guard !options.isEmpty else {
            throw RemoteFileSystemOperationError(status: .invalidPath, path: path)
        }
        var payload = SFTPDataWriter()
        payload.appendString(path)
        payload.appendUInt32(Self.openFlags(options))
        payload.appendAttributes(Self.wireAttributes(attributes, defaultPermissions: Self.fileMode))
        let response = try await request(type: .open, payload: payload.data, expecting: [.handle])
        try throwIfStatus(response, path: path)
        let remoteHandle = try codecConfiguration.handle(from: response)
        let handle = ExecSFTPRemoteFileHandle(
            remoteHandle: remoteHandle,
            owner: self,
            maximumChunkSize: Self.transferChunkSize
        ) { [weak self] handleID in
            await self?.removeFileHandle(id: handleID)
        }
        fileHandles[handle.id] = handle
        return handle
    }

    public func createDirectory(path: String, attributes: RemoteFileAttributes?) async throws {
        try ensureReady(path: path)
        var payload = SFTPDataWriter()
        payload.appendString(path)
        payload.appendAttributes(Self.wireAttributes(attributes, defaultPermissions: Self.directoryMode))
        try await requireOK(type: .mkdir, payload: payload.data, path: path)
    }

    public func removeFile(path: String) async throws {
        try await pathMutation(type: .remove, path: path)
    }

    public func removeDirectory(path: String) async throws {
        try await pathMutation(type: .rmdir, path: path)
    }

    public func rename(from sourcePath: String, to destinationPath: String, overwrite: Bool) async throws {
        try ensureReady(path: sourcePath)
        var payload = SFTPDataWriter()
        if overwrite, serverExtensions["posix-rename@openssh.com"] != nil {
            payload.appendString("posix-rename@openssh.com")
            payload.appendString(sourcePath)
            payload.appendString(destinationPath)
            try await requireOK(type: .extended, payload: payload.data, path: sourcePath)
            return
        }
        payload.appendString(sourcePath)
        payload.appendString(destinationPath)
        try await requireOK(type: .rename, payload: payload.data, path: sourcePath)
    }

    public func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try ensureReady(path: path)
        var payload = SFTPDataWriter()
        payload.appendString(path)
        payload.appendAttributes(Self.wireAttributes(attributes, defaultPermissions: nil))
        try await requireOK(type: .setstat, payload: payload.data, path: path)
    }

    public func readSymbolicLink(path: String) async throws -> String {
        try ensureReady(path: path)
        var payload = SFTPDataWriter()
        payload.appendString(path)
        let response = try await request(type: .readlink, payload: payload.data, expecting: [.name])
        try throwIfStatus(response, path: path)
        guard let target = try codecConfiguration.names(from: response).first?.filename else {
            throw RemoteFileSystemOperationError(status: .malformedResponse, path: path)
        }
        return target
    }

    public func createSymbolicLink(path: String, target: String) async throws {
        try ensureReady(path: path)
        var payload = SFTPDataWriter()
        // OpenSSH sftp-server uses target/link order, opposite the SFTP v3 draft.
        payload.appendString(target)
        payload.appendString(path)
        try await requireOK(type: .symlink, payload: payload.data, path: path)
    }

    public func close() async {
        guard case .closed = state else {
            state = .closed
            readerTask?.cancel()
            readerTask = nil
            let handles = Array(fileHandles.values)
            fileHandles.removeAll(keepingCapacity: false)
            for handle in handles {
                await handle.close()
            }
            versionContinuation.finish(throwing: SFTPWireError.channelClosed)
            await multiplexer.failAll(SFTPWireError.channelClosed)
            try? await execution.finishStandardInput()
            await execution.cancel()
            await notifyCloseIfNeeded()
            return
        }
    }

    fileprivate func read(handle: Data, offset: UInt64, maximumBytes: Int) async throws -> Data {
        try ensureReady(path: nil)
        var payload = SFTPDataWriter()
        payload.appendDataString(handle)
        payload.appendUInt64(offset)
        payload.appendUInt32(UInt32(min(max(1, maximumBytes), Self.transferChunkSize)))
        let response = try await request(type: .read, payload: payload.data, expecting: [.data])
        if response.type == SFTPMessageType.status.rawValue {
            let status = try codecConfiguration.status(from: response)
            if status.code == SFTPStatusCode.endOfFile.rawValue { return Data() }
            throw statusError(status, path: nil)
        }
        return try codecConfiguration.fileData(from: response)
    }

    fileprivate func write(handle: Data, offset: UInt64, data: Data) async throws -> Int {
        try ensureReady(path: nil)
        let chunk = Data(data.prefix(Self.transferChunkSize))
        guard !chunk.isEmpty else { return 0 }
        var payload = SFTPDataWriter()
        payload.appendDataString(handle)
        payload.appendUInt64(offset)
        payload.appendDataString(chunk)
        try await requireOK(type: .write, payload: payload.data, path: nil)
        return chunk.count
    }

    fileprivate func closeFileHandle(_ handle: Data) async {
        try? await closeHandle(handle, path: nil)
    }

    private func start() async throws {
        readerTask = Task { [weak self] in await self?.pumpEvents() }
        try await execution.start()
        try await execution.writeStandardInput(SFTPCodec.initialization())
        let version = try await waitForVersion(timeout: .seconds(10))
        guard version == SFTPCodec.protocolVersion else {
            throw SFTPWireError.invalidVersion(version)
        }
    }

    private func waitForVersion(timeout: Duration) async throws -> UInt32 {
        let stream = versionStream
        return try await withThrowingTaskGroup(of: UInt32.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let version = try await iterator.next() else {
                    throw SFTPWireError.channelClosed
                }
                return version
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteOperationError(
                    category: .privilege,
                    code: "administrator_sftp_handshake_timeout",
                    safeDiagnosticMessage: "Administrator SFTP server did not complete protocol negotiation"
                )
            }
            guard let result = try await group.next() else { throw SFTPWireError.channelClosed }
            group.cancelAll()
            return result
        }
    }

    private func pumpEvents() async {
        do {
            let events = await execution.events()
            for try await event in events {
                switch event {
                case .standardOutput(let data):
                    try await receiveStandardOutput(data)
                case .standardError(let data):
                    captureStandardError(data)
                case .exitStatus(let status):
                    try decoder.finish()
                    throw channelExitError(status: status)
                }
            }
            try decoder.finish()
            throw SFTPWireError.channelClosed
        } catch is CancellationError {
            return
        } catch {
            await fail(error)
        }
    }

    private func receiveStandardOutput(_ data: Data) async throws {
        for packet in try decoder.append(data) {
            switch state {
            case .awaitingVersion:
                let version = try codecConfiguration.parseVersion(packet)
                guard version.version == SFTPCodec.protocolVersion else {
                    throw SFTPWireError.invalidVersion(version.version)
                }
                serverExtensions = version.extensions
                state = .ready
                versionContinuation.yield(version.version)
                versionContinuation.finish()
            case .ready:
                guard packet.type != SFTPMessageType.version.rawValue else {
                    throw SFTPWireError.unexpectedPacketType(packet.type)
                }
                try await multiplexer.receive(packet)
            case .failed(let error):
                throw error
            case .closed:
                throw SFTPWireError.channelClosed
            }
        }
    }

    private func captureStandardError(_ data: Data) {
        let remaining = Self.maximumCapturedStderrBytes - standardError.count
        if remaining > 0 {
            standardError.append(data.prefix(remaining))
        }
    }

    private func channelExitError(status: Int32) -> RemoteOperationError {
        let diagnostic = String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let awaitingVersion: Bool
        if case .awaitingVersion = state { awaitingVersion = true } else { awaitingVersion = false }
        return RemoteOperationError(
            category: awaitingVersion ? .privilege : .fileSystem,
            code: awaitingVersion ? "administrator_sftp_start_failed" : "administrator_sftp_channel_closed",
            safeDiagnosticMessage: diagnostic.isEmpty
                ? "Administrator SFTP server exited with status \(status)"
                : diagnostic,
            backendCode: Int(status)
        )
    }

    private func fail(_ error: Error) async {
        switch state {
        case .awaitingVersion, .ready:
            state = .failed(error)
            versionContinuation.finish(throwing: error)
            await multiplexer.failAll(error)
            await execution.cancel()
            await notifyCloseIfNeeded()
        case .failed, .closed:
            break
        }
    }

    private func notifyCloseIfNeeded() async {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        await onClose(id)
    }

    private func request(
        type: SFTPMessageType,
        payload: Data,
        expecting: Set<SFTPMessageType>
    ) async throws -> SFTPPacket {
        try ensureReady(path: nil)
        return try await multiplexer.request(
            type: type,
            payload: payload,
            expecting: expecting
        ) { [execution] frame in
            try await execution.writeStandardInput(frame)
        }
    }

    private func requireOK(type: SFTPMessageType, payload: Data, path: String?) async throws {
        let response = try await request(type: type, payload: payload, expecting: [])
        guard response.type == SFTPMessageType.status.rawValue else {
            throw RemoteFileSystemOperationError(status: .malformedResponse, path: path)
        }
        let status = try codecConfiguration.status(from: response)
        guard status.code == SFTPStatusCode.ok.rawValue else {
            throw statusError(status, path: path)
        }
    }

    private func closeHandle(_ handle: Data, path: String?) async throws {
        var payload = SFTPDataWriter()
        payload.appendDataString(handle)
        try await requireOK(type: .close, payload: payload.data, path: path)
    }

    private func pathMutation(type: SFTPMessageType, path: String) async throws {
        try ensureReady(path: path)
        var payload = SFTPDataWriter()
        payload.appendString(path)
        try await requireOK(type: type, payload: payload.data, path: path)
    }

    private func throwIfStatus(_ packet: SFTPPacket, path: String?) throws {
        if packet.type == SFTPMessageType.status.rawValue {
            throw statusError(try codecConfiguration.status(from: packet), path: path)
        }
    }

    private func statusError(_ status: SFTPStatus, path: String?) -> RemoteFileSystemOperationError {
        let mappedStatus: RemoteFileSystemStatus
        switch status.code {
        case SFTPStatusCode.ok.rawValue:
            mappedStatus = .malformedResponse
        case SFTPStatusCode.noSuchFile.rawValue:
            mappedStatus = .notFound
        case SFTPStatusCode.permissionDenied.rawValue:
            mappedStatus = .permissionDenied
        case SFTPStatusCode.operationUnsupported.rawValue:
            mappedStatus = .unsupported
        case SFTPStatusCode.noConnection.rawValue, SFTPStatusCode.connectionLost.rawValue:
            mappedStatus = .connectionLost
        case SFTPStatusCode.badMessage.rawValue:
            mappedStatus = .malformedResponse
        default:
            mappedStatus = .unknown
        }
        return RemoteFileSystemOperationError(
            status: mappedStatus,
            path: path,
            backendCode: Int(status.code)
        )
    }

    private func ensureReady(path: String?) throws {
        switch state {
        case .ready:
            return
        case .failed(let error):
            throw error
        case .awaitingVersion, .closed:
            throw RemoteFileSystemOperationError(status: .connectionLost, path: path)
        }
    }

    private func removeFileHandle(id: UUID) {
        fileHandles.removeValue(forKey: id)
    }

    private static func openFlags(_ options: RemoteFileOpenOptions) -> UInt32 {
        var flags: UInt32 = 0
        if options.contains(.read) { flags |= 0x0000_0001 }
        if options.contains(.write) { flags |= 0x0000_0002 }
        if options.contains(.append) { flags |= 0x0000_0004 }
        if options.contains(.create) { flags |= 0x0000_0008 }
        if options.contains(.truncate) { flags |= 0x0000_0010 }
        if options.contains(.exclusive) { flags |= 0x0000_0020 }
        return flags
    }

    private static func wireAttributes(
        _ attributes: RemoteFileAttributes?,
        defaultPermissions: UInt32?
    ) -> SFTPFileAttributes {
        guard let attributes else {
            return SFTPFileAttributes(permissions: defaultPermissions)
        }
        let uid = attributes.owner.flatMap(UInt32.init)
        let gid = attributes.group.flatMap(UInt32.init)
        let timestamp = UInt32(clamping: Int64(attributes.modifiedAt.timeIntervalSince1970))
        return SFTPFileAttributes(
            uid: uid,
            gid: gid,
            permissions: attributes.permissions.map(UInt32.init) ?? defaultPermissions,
            accessTime: timestamp,
            modificationTime: timestamp
        )
    }

    private static func remoteAttributes(_ attributes: SFTPFileAttributes) -> RemoteFileAttributes {
        let mode = attributes.permissions ?? 0
        return RemoteFileAttributes(
            permissions: attributes.permissions.map { UInt16(truncatingIfNeeded: $0 & 0o7777) },
            owner: attributes.uid.map(String.init),
            group: attributes.gid.map(String.init),
            size: attributes.size.map(Int64.init(clamping:)) ?? 0,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(attributes.modificationTime ?? 0)),
            isDirectory: attributes.permissions != nil && (mode & 0o170000) == 0o040000,
            isSymbolicLink: attributes.permissions != nil && (mode & 0o170000) == 0o120000
        )
    }

    private static func remoteEntry(path: String, entry: SFTPNameEntry) -> RemoteFileEntry {
        let attributes = remoteAttributes(entry.attributes)
        return RemoteFileEntry(
            name: entry.filename,
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

    private static func join(parent: String, name: String) -> String {
        parent == "/" ? "/\(name)" : parent + "/" + name
    }
}

private actor ExecSFTPRemoteFileHandle: RemoteFileHandleProtocol {
    nonisolated let id = UUID()

    private let remoteHandle: Data
    private let owner: ExecSFTPRemoteFileSystem
    private let maximumChunkSize: Int
    private let onClose: @Sendable (UUID) async -> Void
    private var offset: UInt64 = 0
    private var closed = false

    init(
        remoteHandle: Data,
        owner: ExecSFTPRemoteFileSystem,
        maximumChunkSize: Int,
        onClose: @escaping @Sendable (UUID) async -> Void
    ) {
        self.remoteHandle = remoteHandle
        self.owner = owner
        self.maximumChunkSize = maximumChunkSize
        self.onClose = onClose
    }

    func read(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw RemoteFileSystemOperationError(status: .connectionLost) }
        let data = try await owner.read(
            handle: remoteHandle,
            offset: offset,
            maximumBytes: min(maximumBytes, maximumChunkSize)
        )
        offset += UInt64(data.count)
        return data
    }

    func write(_ data: Data) async throws -> Int {
        guard !closed else { throw RemoteFileSystemOperationError(status: .connectionLost) }
        let written = try await owner.write(
            handle: remoteHandle,
            offset: offset,
            data: Data(data.prefix(maximumChunkSize))
        )
        offset += UInt64(written)
        return written
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await owner.closeFileHandle(remoteHandle)
        await onClose(id)
    }
}
