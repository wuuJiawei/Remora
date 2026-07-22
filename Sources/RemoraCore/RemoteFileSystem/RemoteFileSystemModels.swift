import Foundation

public struct RemoteFileOpenOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let read = RemoteFileOpenOptions(rawValue: 1 << 0)
    public static let write = RemoteFileOpenOptions(rawValue: 1 << 1)
    public static let append = RemoteFileOpenOptions(rawValue: 1 << 2)
    public static let create = RemoteFileOpenOptions(rawValue: 1 << 3)
    public static let truncate = RemoteFileOpenOptions(rawValue: 1 << 4)
    public static let exclusive = RemoteFileOpenOptions(rawValue: 1 << 5)
}

public struct RemoteFileSystemCapabilities: Equatable, Sendable {
    public let supportsSymbolicLinks: Bool
    public let supportsAtomicRename: Bool
    public let supportsAttributeUpdates: Bool

    public init(
        supportsSymbolicLinks: Bool,
        supportsAtomicRename: Bool,
        supportsAttributeUpdates: Bool
    ) {
        self.supportsSymbolicLinks = supportsSymbolicLinks
        self.supportsAtomicRename = supportsAtomicRename
        self.supportsAttributeUpdates = supportsAttributeUpdates
    }
}

public enum RemoteFileSystemStatus: String, Equatable, Sendable {
    case notFound
    case permissionDenied
    case alreadyExists
    case invalidPath
    case unsupported
    case malformedResponse
    case connectionLost
    case unknown
}

public struct RemoteFileSystemOperationError: Error, Equatable, Sendable {
    public let status: RemoteFileSystemStatus
    public let path: String?
    public let backendCode: Int?

    public init(status: RemoteFileSystemStatus, path: String? = nil, backendCode: Int? = nil) {
        self.status = status
        self.path = path
        self.backendCode = backendCode
    }
}
