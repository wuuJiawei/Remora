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
