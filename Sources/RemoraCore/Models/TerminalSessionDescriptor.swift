import Foundation

public struct TerminalSessionDescriptor: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let host: Host
    public let createdAt: Date
    public let usesStoredPasswordDelivery: Bool

    public init(
        id: UUID = UUID(),
        host: Host,
        createdAt: Date = Date(),
        usesStoredPasswordDelivery: Bool = false
    ) {
        self.id = id
        self.host = host
        self.createdAt = createdAt
        self.usesStoredPasswordDelivery = usesStoredPasswordDelivery
    }
}
