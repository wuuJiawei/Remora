import Foundation

public actor SessionManager: SessionManagerProtocol {
    private struct SessionContainer {
        let descriptor: TerminalSessionDescriptor
        let shell: SSHTransportSessionProtocol
        let stream: AsyncStream<Data>
        let continuation: AsyncStream<Data>.Continuation
        let stateStream: AsyncStream<ShellSessionState>
        let stateContinuation: AsyncStream<ShellSessionState>.Continuation
    }

    private let sshClientFactory: @Sendable () -> SSHTransportClientProtocol
    private var sessions: [UUID: SessionContainer] = [:]

    public init(sshClientFactory: @escaping @Sendable () -> SSHTransportClientProtocol) {
        self.sshClientFactory = sshClientFactory
    }

    public func startSession(for host: Host, pty: PTYSize) async throws -> TerminalSessionDescriptor {
        let client = sshClientFactory()
        try await client.connect(to: host)
        let shell = try await client.openShell(pty: pty)

        let descriptor = TerminalSessionDescriptor(host: host)
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
            case .idle, .running:
                break
            }
        }

        try await shell.start()

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

    public func activeSessions() async -> [TerminalSessionDescriptor] {
        sessions.values.map(\.descriptor).sorted { $0.createdAt < $1.createdAt }
    }
}
