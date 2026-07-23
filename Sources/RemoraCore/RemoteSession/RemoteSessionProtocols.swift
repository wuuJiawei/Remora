import Foundation

public struct RemoteSessionIdentitySnapshot: Equatable, Sendable {
    public let sessionID: UUID
    public let key: RemoteSessionKey
    public let state: RemoteSessionState

    public init(sessionID: UUID, key: RemoteSessionKey, state: RemoteSessionState) {
        self.sessionID = sessionID
        self.key = key
        self.state = state
    }
}

public enum RemoteShellEvent: Equatable, Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case exitStatus(Int32)
    case endOfFile
}

public protocol RemoteShellChannelProtocol: AnyObject, Sendable {
    var id: UUID { get }
    func start() async throws
    func write(_ data: Data) async throws
    func resize(_ size: PTYSize) async throws
    func events() async -> AsyncThrowingStream<RemoteShellEvent, Error>
    func close() async
}

public protocol RemoteSessionProtocol: AnyObject, Sendable {
    var id: UUID { get }
    func identitySnapshot() async -> RemoteSessionIdentitySnapshot
    func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol
    func commandExecutor() async throws -> any RemoteCommandExecutorProtocol
    func fileSystem() async throws -> any RemoteFileSystemProtocol
    func close() async
}

public protocol RemoteSessionLeaseProtocol: AnyObject, Sendable {
    var id: UUID { get }
    func session() async throws -> any RemoteSessionProtocol
    func release() async
}
