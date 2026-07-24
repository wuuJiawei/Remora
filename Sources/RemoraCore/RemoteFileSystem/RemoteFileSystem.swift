import Foundation

public protocol RemoteFileHandleProtocol: AnyObject, Sendable {
    var id: UUID { get }
    func read(maximumBytes: Int) async throws -> Data
    func write(_ data: Data) async throws -> Int
    func close() async
}

public protocol RemoteFileSystem: AnyObject, Sendable {
    func capabilities() async -> RemoteFileSystemCapabilities
    func listDirectory(path: String) async throws -> [RemoteFileEntry]
    func attributes(path: String, followSymbolicLinks: Bool) async throws -> RemoteFileAttributes
    func openFile(
        path: String,
        options: RemoteFileOpenOptions,
        attributes: RemoteFileAttributes?
    ) async throws -> any RemoteFileHandleProtocol
    func createDirectory(path: String, attributes: RemoteFileAttributes?) async throws
    func removeFile(path: String) async throws
    func removeDirectory(path: String) async throws
    func rename(from sourcePath: String, to destinationPath: String, overwrite: Bool) async throws
    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws
    func readSymbolicLink(path: String) async throws -> String
    func createSymbolicLink(path: String, target: String) async throws
    func close() async
}
