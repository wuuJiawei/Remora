import Foundation

public actor DisconnectedSFTPClient: SFTPClientProtocol {
    public init() {}

    public func list(path: String) async throws -> [RemoteFileEntry] {
        _ = path
        throw SSHError.notConnected
    }

    public func download(path: String) async throws -> Data {
        _ = path
        throw SSHError.notConnected
    }

    public func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws {
        _ = path
        _ = localFileURL
        _ = progress
        throw SSHError.notConnected
    }

    public func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String {
        _ = command
        _ = timeout
        throw SSHError.notConnected
    }

    public func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> {
        _ = command
        throw SSHError.notConnected
    }

    public func upload(data: Data, to path: String) async throws {
        _ = data
        _ = path
        throw SSHError.notConnected
    }

    public func rename(from: String, to: String) async throws {
        _ = from
        _ = to
        throw SSHError.notConnected
    }

    public func mkdir(path: String) async throws {
        _ = path
        throw SSHError.notConnected
    }

    public func remove(path: String) async throws {
        _ = path
        throw SSHError.notConnected
    }
}
