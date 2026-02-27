import Foundation

public protocol SessionManagerProtocol: Sendable {
    func startSession(for host: Host, pty: PTYSize) async throws -> TerminalSessionDescriptor
    func stopSession(id: UUID) async
    func write(_ data: Data, to sessionID: UUID) async throws
    func resize(sessionID: UUID, pty: PTYSize) async throws
    func sessionOutputStream(sessionID: UUID) async -> AsyncStream<Data>
    func sessionStateStream(sessionID: UUID) async -> AsyncStream<ShellSessionState>
    func activeSessions() async -> [TerminalSessionDescriptor]
}
