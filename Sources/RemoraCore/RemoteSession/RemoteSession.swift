import Foundation

public protocol RemoteSessionTransportProtocol: Sendable {
    func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol
    func close() async
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

    public func close() async {
        guard state.phase != .closing, state.phase != .closed else { return }
        state = .closing

        let activeChannels = Array(channels.values)
        channels.removeAll(keepingCapacity: false)
        for channel in activeChannels {
            await channel.close()
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
