import Foundation

public actor SessionManager: SessionManagerProtocol {
    public typealias RemoteRequestBuilder = @Sendable (Host) async throws -> RemoteSessionAcquisitionRequest

    private enum Backend: Sendable {
        case process(@Sendable () -> SSHTransportClientProtocol)
        case remote(RemoteSessionHub, RemoteRequestBuilder)
    }

    private struct SessionContainer {
        let descriptor: TerminalSessionDescriptor
        let shell: SSHTransportSessionProtocol
        let stream: AsyncStream<Data>
        let continuation: AsyncStream<Data>.Continuation
        let stateStream: AsyncStream<ShellSessionState>
        let stateContinuation: AsyncStream<ShellSessionState>.Continuation
    }

    private let backend: Backend
    private var sessions: [UUID: SessionContainer] = [:]

    public init(sshClientFactory: @escaping @Sendable () -> SSHTransportClientProtocol) {
        backend = .process(sshClientFactory)
    }

    public init(
        remoteSessionHub: RemoteSessionHub,
        requestBuilder: @escaping RemoteRequestBuilder
    ) {
        backend = .remote(remoteSessionHub, requestBuilder)
    }

    public func startSession(for host: Host, pty: PTYSize) async throws -> TerminalSessionDescriptor {
        let shell: SSHTransportSessionProtocol
        let remoteIdentity: RemoteSessionIdentitySnapshot?
        switch backend {
        case .process(let clientFactory):
            let client = clientFactory()
            try await client.connect(to: host)
            shell = try await client.openShell(pty: pty)
            remoteIdentity = nil
        case .remote(let hub, let requestBuilder):
            let request = try await requestBuilder(host)
            let lease = try await hub.acquire(key: request.key, create: request.createSession)
            do {
                let remoteSession = try await lease.session()
                let remoteShell = try await remoteSession.openShell(pty: pty)
                shell = RemoteShellSessionAdapter(channel: remoteShell, lease: lease)
                remoteIdentity = await remoteSession.identitySnapshot()
            } catch {
                await lease.release()
                throw error
            }
        }

        let descriptorID = UUID()
        let createdAt = Date()
        let pair = AsyncStream.makeStream(of: Data.self)
        let stream = pair.stream
        let continuation = pair.continuation
        let statePair = AsyncStream.makeStream(of: ShellSessionState.self)
        let stateStream = statePair.stream
        let stateContinuation = statePair.continuation

        shell.onOutput = { output in
            continuation.yield(output)
        }

        shell.onStateChange = { state in
            stateContinuation.yield(state)
            switch state {
            case .stopped, .failed:
                continuation.finish()
                stateContinuation.finish()
                Task { [weak self] in
                    await self?.removeTerminatedSession(id: descriptorID)
                }
            case .idle, .running:
                break
            }
        }

        try await shell.start()

        let descriptor = TerminalSessionDescriptor(
            id: descriptorID,
            host: host,
            createdAt: createdAt,
            usesStoredPasswordDelivery: shell.usesStoredPasswordDelivery,
            remoteSessionIdentity: remoteIdentity
        )

        sessions[descriptor.id] = SessionContainer(
            descriptor: descriptor,
            shell: shell,
            stream: stream,
            continuation: continuation,
            stateStream: stateStream,
            stateContinuation: stateContinuation
        )
        return descriptor
    }

    public func stopSession(id: UUID) async {
        guard let container = sessions.removeValue(forKey: id) else { return }
        await container.shell.stop()
        container.continuation.finish()
        container.stateContinuation.finish()
    }

    public func write(_ data: Data, to sessionID: UUID) async throws {
        guard let container = sessions[sessionID] else {
            throw SSHError.notConnected
        }
        try await container.shell.write(data)
    }

    public func resize(sessionID: UUID, pty: PTYSize) async throws {
        guard let container = sessions[sessionID] else {
            throw SSHError.notConnected
        }
        try await container.shell.resize(pty)
    }

    public func sessionOutputStream(sessionID: UUID) async -> AsyncStream<Data> {
        sessions[sessionID]?.stream ?? AsyncStream<Data> { continuation in
            continuation.finish()
        }
    }

    public func sessionStateStream(sessionID: UUID) async -> AsyncStream<ShellSessionState> {
        sessions[sessionID]?.stateStream ?? AsyncStream<ShellSessionState> { continuation in
            continuation.finish()
        }
    }

    public func remoteSessionIdentity(sessionID: UUID) -> RemoteSessionIdentitySnapshot? {
        sessions[sessionID]?.descriptor.remoteSessionIdentity
    }

    public func acquireRemoteSessionLease(sessionID: UUID) async throws -> any RemoteSessionLeaseProtocol {
        guard let identity = sessions[sessionID]?.descriptor.remoteSessionIdentity else {
            throw RemoteOperationError(
                category: .session,
                code: "native_session_unavailable",
                safeDiagnosticMessage: "Terminal is not attached to a native remote session"
            )
        }
        guard case .remote(let hub, _) = backend else {
            throw RemoteOperationError(
                category: .session,
                code: "native_session_unavailable",
                safeDiagnosticMessage: "Session manager does not own a native remote session hub"
            )
        }
        return try await hub.acquireExisting(key: identity.key)
    }

    public func activeSessions() async -> [TerminalSessionDescriptor] {
        sessions.values.map(\.descriptor).sorted { $0.createdAt < $1.createdAt }
    }

    private func removeTerminatedSession(id: UUID) async {
        guard let container = sessions.removeValue(forKey: id) else { return }
        await container.shell.stop()
    }
}

private final class RemoteShellSessionAdapter: SSHTransportSessionProtocol, @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (ShellSessionState) -> Void)?
    let usesStoredPasswordDelivery = false

    private let channel: any RemoteShellChannelProtocol
    private let lease: any RemoteSessionLeaseProtocol
    private let lock = NSLock()
    private var isStopped = false
    private var eventTask: Task<Void, Never>?

    init(
        channel: any RemoteShellChannelProtocol,
        lease: any RemoteSessionLeaseProtocol
    ) {
        self.channel = channel
        self.lease = lease
    }

    deinit {
        eventTask?.cancel()
    }

    func start() async throws {
        try await channel.start()
        onStateChange?(.running)
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                let events = await channel.events()
                for try await event in events {
                    switch event {
                    case .standardOutput(let data), .standardError(let data):
                        onOutput?(data)
                    case .exitStatus:
                        break
                    case .endOfFile:
                        await finish(state: .stopped)
                        return
                    }
                }
                await finish(state: .stopped)
            } catch is CancellationError {
                await finish(state: .stopped)
            } catch {
                await finish(state: .failed(Self.safeFailureDescription(error)))
            }
        }
    }

    func write(_ data: Data) async throws {
        try await channel.write(data)
    }

    func resize(_ size: PTYSize) async throws {
        try await channel.resize(size)
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await finish(state: .stopped)
    }

    private func finish(state: ShellSessionState) async {
        let shouldFinish = lock.withLock {
            guard !isStopped else { return false }
            isStopped = true
            return true
        }
        guard shouldFinish else { return }

        await channel.close()
        await lease.release()
        onStateChange?(state)
    }

    private static func safeFailureDescription(_ error: Error) -> String {
        if let operationError = error as? RemoteOperationError {
            return "\(operationError.code): \(operationError.safeDiagnosticMessage)"
        }
        return "remote_shell_failed"
    }
}
