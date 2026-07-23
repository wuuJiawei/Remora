import Foundation

public protocol RemoteSessionTransportProtocol: Sendable {
    func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol
    func openDirectTCPIP(
        destinationHost: String,
        destinationPort: Int,
        sourceHost: String,
        sourcePort: Int
    ) async throws -> any RemoteForwardChannelProtocol
    func close() async
}

public extension RemoteSessionTransportProtocol {
    func openDirectTCPIP(
        destinationHost: String,
        destinationPort: Int,
        sourceHost: String,
        sourcePort: Int
    ) async throws -> any RemoteForwardChannelProtocol {
        throw RemoteOperationError(
            category: .channel,
            code: "direct_tcpip_unavailable",
            safeDiagnosticMessage: "Remote session transport does not support direct TCP/IP channels"
        )
    }
}

extension LibSSH2Transport: RemoteSessionTransportProtocol {
    public func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol {
        try await openShell(pty: pty, terminalType: "xterm-256color")
    }
}

public actor RemoteSession: RemoteSessionProtocol {
    public nonisolated let id: UUID

    private let key: RemoteSessionKey
    private let transport: any RemoteSessionTransportProtocol
    private var state: RemoteSessionState
    private var channels: [UUID: ManagedRemoteShellChannel] = [:]
    private var forwardChannels: [UUID: ManagedRemoteForwardChannel] = [:]
    private var fileSystems: [UUID: any RemoteFileSystemProtocol] = [:]
    private var openingFileSystemIDs: Set<UUID> = []

    public init(
        id: UUID = UUID(),
        key: RemoteSessionKey,
        transport: any RemoteSessionTransportProtocol,
        initialState: RemoteSessionState = .ready
    ) {
        self.id = id
        self.key = key
        self.transport = transport
        state = initialState
    }

    public func identitySnapshot() -> RemoteSessionIdentitySnapshot {
        RemoteSessionIdentitySnapshot(sessionID: id, key: key, state: state)
    }

    public func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol {
        guard state == .ready else {
            throw RemoteOperationError(
                category: .session,
                code: "session_not_ready",
                safeDiagnosticMessage: "Remote session is not ready for a shell channel"
            )
        }

        let channel = try await transport.openShell(pty: pty)
        let managed = ManagedRemoteShellChannel(channel: channel) { [weak self] channelID in
            await self?.removeChannel(id: channelID)
        }
        channels[managed.id] = managed
        return managed
    }

    public func commandExecutor() throws -> any RemoteCommandExecutorProtocol {
        try requireBoundTarget(capability: "remote commands")
        guard state == .ready, let transport = transport as? LibSSH2Transport else {
            throw RemoteOperationError(
                category: .session,
                code: "command_capability_unavailable",
                safeDiagnosticMessage: "Remote session does not provide native command execution"
            )
        }
        return LibSSH2CommandExecutor(transport: transport)
    }

    public func openDirectTCPIP(
        destinationHost: String,
        destinationPort: Int,
        sourceHost: String,
        sourcePort: Int
    ) async throws -> any RemoteForwardChannelProtocol {
        try requireBoundTarget(capability: "port forwarding")
        guard state == .ready else {
            throw sessionNotReadyError(capability: "port forwarding")
        }
        let channel = try await transport.openDirectTCPIP(
            destinationHost: destinationHost,
            destinationPort: destinationPort,
            sourceHost: sourceHost,
            sourcePort: sourcePort
        )
        guard state == .ready else {
            await channel.close()
            throw sessionNotReadyError(capability: "port forwarding")
        }
        let managed = ManagedRemoteForwardChannel(channel: channel) { [weak self] channelID in
            await self?.removeForwardChannel(id: channelID)
        }
        forwardChannels[managed.id] = managed
        return managed
    }

    public func fileSystem() async throws -> any RemoteFileSystemProtocol {
        try requireBoundTarget(capability: "file access")
        guard state == .ready, let transport = transport as? LibSSH2Transport else {
            throw RemoteOperationError(
                category: .session,
                code: "file_system_capability_unavailable",
                safeDiagnosticMessage: "Remote session does not provide native file access"
            )
        }
        let registrationID = UUID()
        openingFileSystemIDs.insert(registrationID)
        let fileSystem: LibSSH2RemoteFileSystem
        do {
            fileSystem = try await transport.openFileSystem { [weak self] _ in
                await self?.removeFileSystem(id: registrationID)
            }
        } catch {
            openingFileSystemIDs.remove(registrationID)
            throw error
        }
        guard openingFileSystemIDs.remove(registrationID) != nil else {
            await fileSystem.close()
            throw capabilityClosedDuringOpenError(capability: "file access")
        }
        guard state == .ready else {
            await fileSystem.close()
            throw sessionNotReadyError(capability: "file access")
        }
        fileSystems[registrationID] = fileSystem
        return fileSystem
    }

    public func administratorFileSystem() async throws -> any RemoteFileSystemProtocol {
        try requireBoundTarget(capability: "administrator file access")
        guard state == .ready, let transport = transport as? LibSSH2Transport else {
            throw RemoteOperationError(
                category: .session,
                code: "administrator_file_system_capability_unavailable",
                safeDiagnosticMessage: "Remote session does not provide administrator file access"
            )
        }

        let resolver = try AdministratorSFTPServerResolver()
        let executor = LibSSH2CommandExecutor(transport: transport)
        let serverPath = try await resolver.resolve(using: executor)
        guard state == .ready else {
            throw sessionNotReadyError(capability: "administrator file access")
        }

        let registrationID = UUID()
        openingFileSystemIDs.insert(registrationID)
        let fileSystem: ExecSFTPRemoteFileSystem
        do {
            fileSystem = try await ExecSFTPRemoteFileSystem.open(
                transport: transport,
                serverPath: serverPath
            ) { [weak self] _ in
                await self?.removeFileSystem(id: registrationID)
            }
        } catch {
            openingFileSystemIDs.remove(registrationID)
            throw error
        }
        guard openingFileSystemIDs.remove(registrationID) != nil else {
            await fileSystem.close()
            throw capabilityClosedDuringOpenError(capability: "administrator file access")
        }
        guard state == .ready else {
            await fileSystem.close()
            throw sessionNotReadyError(capability: "administrator file access")
        }
        fileSystems[registrationID] = fileSystem
        return fileSystem
    }

    public func close() async {
        guard state.phase != .closing, state.phase != .closed else { return }
        state = .closing

        let activeChannels = Array(channels.values)
        channels.removeAll(keepingCapacity: false)
        for channel in activeChannels {
            await channel.close()
        }
        let activeForwardChannels = Array(forwardChannels.values)
        forwardChannels.removeAll(keepingCapacity: false)
        for channel in activeForwardChannels {
            await channel.close()
        }
        let activeFileSystems = Array(fileSystems.values)
        fileSystems.removeAll(keepingCapacity: false)
        for fileSystem in activeFileSystems {
            await fileSystem.close()
        }
        await transport.close()
        state = .closed
    }

    public func activeChannelCount() -> Int {
        channels.count
    }

    private func removeChannel(id: UUID) {
        channels.removeValue(forKey: id)
    }

    private func removeForwardChannel(id: UUID) {
        forwardChannels.removeValue(forKey: id)
    }

    private func removeFileSystem(id: UUID) {
        openingFileSystemIDs.remove(id)
        fileSystems.removeValue(forKey: id)
    }

    private func sessionNotReadyError(capability: String) -> RemoteOperationError {
        RemoteOperationError(
            category: .session,
            code: "session_not_ready",
            safeDiagnosticMessage: "Remote session is not ready for \(capability)"
        )
    }

    private func capabilityClosedDuringOpenError(capability: String) -> RemoteOperationError {
        RemoteOperationError(
            category: .fileSystem,
            code: "file_system_closed_during_open",
            safeDiagnosticMessage: "Remote \(capability) closed while it was opening"
        )
    }

    private func requireBoundTarget(capability: String) throws {
        guard key.target.bindingState == .bound else {
            throw RemoteOperationError(
                category: .route,
                code: "target_not_resolved",
                safeDiagnosticMessage: "Select a gateway asset and account before using \(capability)"
            )
        }
    }
}

private actor ManagedRemoteForwardChannel: RemoteForwardChannelProtocol {
    nonisolated let id: UUID

    private let channel: any RemoteForwardChannelProtocol
    private let onClose: @Sendable (UUID) async -> Void
    private var isClosed = false

    init(
        channel: any RemoteForwardChannelProtocol,
        onClose: @escaping @Sendable (UUID) async -> Void
    ) {
        id = channel.id
        self.channel = channel
        self.onClose = onClose
    }

    func read(maximumBytes: Int) async throws -> Data? {
        guard !isClosed else { throw closedError() }
        return try await channel.read(maximumBytes: maximumBytes)
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw closedError() }
        try await channel.write(data)
    }

    func finishWriting() async throws {
        guard !isClosed else { return }
        try await channel.finishWriting()
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await channel.close()
        await onClose(id)
    }

    private func closedError() -> RemoteOperationError {
        RemoteOperationError(
            category: .channel,
            code: "forward_channel_closed",
            safeDiagnosticMessage: "Remote forwarding channel is closed"
        )
    }
}

private actor ManagedRemoteShellChannel: RemoteShellChannelProtocol {
    nonisolated let id: UUID

    private let channel: any RemoteShellChannelProtocol
    private let onClose: @Sendable (UUID) async -> Void
    private var isClosed = false

    init(
        channel: any RemoteShellChannelProtocol,
        onClose: @escaping @Sendable (UUID) async -> Void
    ) {
        id = channel.id
        self.channel = channel
        self.onClose = onClose
    }

    func start() async throws {
        guard !isClosed else { throw closedError() }
        try await channel.start()
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw closedError() }
        try await channel.write(data)
    }

    func resize(_ size: PTYSize) async throws {
        guard !isClosed else { throw closedError() }
        try await channel.resize(size)
    }

    func events() async -> AsyncThrowingStream<RemoteShellEvent, Error> {
        await channel.events()
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await channel.close()
        await onClose(id)
    }

    private func closedError() -> RemoteOperationError {
        RemoteOperationError(
            category: .channel,
            code: "shell_channel_closed",
            safeDiagnosticMessage: "Remote shell channel is closed"
        )
    }
}
