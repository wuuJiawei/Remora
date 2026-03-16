import Foundation

public enum SFTPClientError: Error, LocalizedError, Sendable {
    case notFound(String)
    case invalidPath(String)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "Path not found: \(path)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .unsupportedOperation(let operation):
            return "Operation not supported: \(operation)"
        }
    }
}

public protocol SFTPClientProtocol: Sendable {
    func list(path: String) async throws -> [RemoteFileEntry]
    func download(path: String) async throws -> Data
    func download(path: String, progress: TransferProgressHandler?) async throws -> Data
    func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws
    func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String
    func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error>
    func upload(data: Data, to path: String) async throws
    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws
    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws
    func rename(from: String, to: String) async throws
    func move(from: String, to: String) async throws
    func copy(from: String, to: String) async throws
    func mkdir(path: String) async throws
    func remove(path: String) async throws
    func stat(path: String) async throws -> RemoteFileAttributes
    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws
}

public extension SFTPClientProtocol {
    func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        progress?(.init(bytesTransferred: 0, totalBytes: nil))
        let payload = try await download(path: path)
        progress?(.init(bytesTransferred: Int64(payload.count), totalBytes: Int64(payload.count)))
        return payload
    }

    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws {
        let totalBytes = Int64(data.count)
        progress?(.init(bytesTransferred: 0, totalBytes: totalBytes))
        try await upload(data: data, to: path)
        progress?(.init(bytesTransferred: totalBytes, totalBytes: totalBytes))
    }

    func executeRemoteShellCommand(_ command: String, timeout: TimeInterval? = nil) async throws -> String {
        _ = command
        _ = timeout
        throw SFTPClientError.unsupportedOperation("remote-shell-command")
    }

    func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> {
        _ = command
        throw SFTPClientError.unsupportedOperation("remote-shell-command-stream")
    }

    func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws {
        let payload = try await download(path: path, progress: progress)
        let directory = localFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: localFileURL, options: .atomic)
    }

    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws {
        let fileData = try Data(contentsOf: fileURL)
        try await upload(data: fileData, to: path, progress: progress)
    }

    func move(from: String, to: String) async throws {
        try await rename(from: from, to: to)
    }

    func copy(from: String, to: String) async throws {
        let data = try await download(path: from)
        try await upload(data: data, to: to)
    }

    func stat(path: String) async throws -> RemoteFileAttributes {
        let normalizedPath = sftpNormalize(path)
        if normalizedPath == "/" {
            return RemoteFileAttributes(size: 0, isDirectory: true)
        }

        let parentPath = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
        let parent = parentPath.isEmpty ? "/" : parentPath
        let expectedName = URL(fileURLWithPath: normalizedPath).lastPathComponent
        let entries = try await list(path: parent)

        guard let entry = entries.first(where: {
            sftpNormalize($0.path) == normalizedPath || $0.name == expectedName
        }) else {
            throw SFTPClientError.notFound(normalizedPath)
        }

        return RemoteFileAttributes(
            permissions: entry.permissions,
            owner: entry.owner,
            group: entry.group,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            isDirectory: entry.isDirectory
        )
    }

    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        _ = path
        _ = attributes
        throw SFTPClientError.unsupportedOperation("setAttributes")
    }

    private func sftpNormalize(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        guard path != "/" else { return "/" }
        let leadingSlash = path.hasPrefix("/") ? path : "/\(path)"
        return leadingSlash.replacingOccurrences(of: "//", with: "/")
    }
}

public struct RemoteFileEntry: Equatable, Sendable {
    public var name: String
    public var path: String
    public var size: Int64
    public var permissions: UInt16?
    public var owner: String?
    public var group: String?
    public var isDirectory: Bool
    public var modifiedAt: Date

    public init(
        name: String,
        path: String,
        size: Int64,
        permissions: UInt16? = nil,
        owner: String? = nil,
        group: String? = nil,
        isDirectory: Bool,
        modifiedAt: Date = Date()
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.isDirectory = isDirectory
        self.modifiedAt = modifiedAt
    }
}
