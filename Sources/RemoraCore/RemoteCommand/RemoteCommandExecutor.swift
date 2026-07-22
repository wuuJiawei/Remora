import Foundation

public protocol RemoteCommandExecutionProtocol: AnyObject, Sendable {
    var id: UUID { get }
    func events() async -> AsyncThrowingStream<RemoteCommandEvent, Error>
    func writeStandardInput(_ data: Data) async throws
    func finishStandardInput() async throws
    func cancel() async
}

public protocol RemoteCommandExecutorProtocol: AnyObject, Sendable {
    func start(_ request: RemoteCommandRequest) async throws -> any RemoteCommandExecutionProtocol
    func execute(_ request: RemoteCommandRequest) async throws -> RemoteCommandResult
}
