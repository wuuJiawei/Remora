import Foundation

public struct TransferProgressSnapshot: Equatable, Sendable {
    public var bytesTransferred: Int64
    public var totalBytes: Int64?
    public var speedBytesPerSecond: Double?
    public var estimatedRemainingSeconds: Double?

    public init(
        bytesTransferred: Int64,
        totalBytes: Int64? = nil,
        speedBytesPerSecond: Double? = nil,
        estimatedRemainingSeconds: Double? = nil
    ) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesTransferred) / Double(totalBytes), 0), 1)
    }
}

public typealias TransferProgressHandler = @Sendable (TransferProgressSnapshot) -> Void

public struct RemoteFileAttributes: Equatable, Sendable {
    public var permissions: UInt16?
    public var owner: String?
    public var group: String?
    public var size: Int64
    public var modifiedAt: Date
    public var isDirectory: Bool

    public init(
        permissions: UInt16? = nil,
        owner: String? = nil,
        group: String? = nil,
        size: Int64,
        modifiedAt: Date = Date(),
        isDirectory: Bool
    ) {
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.size = size
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}
