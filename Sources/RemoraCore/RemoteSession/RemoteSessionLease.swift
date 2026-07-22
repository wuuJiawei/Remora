import Foundation

public actor RemoteSessionLease: RemoteSessionLeaseProtocol {
    public nonisolated let id: UUID

    private let remoteSession: any RemoteSessionProtocol
    private let releaseHandler: @Sendable (UUID) async -> Void
    private var isReleased = false

    init(
        id: UUID = UUID(),
        session: any RemoteSessionProtocol,
        releaseHandler: @escaping @Sendable (UUID) async -> Void
    ) {
        self.id = id
        remoteSession = session
        self.releaseHandler = releaseHandler
    }

    public func session() throws -> any RemoteSessionProtocol {
        guard !isReleased else {
            throw RemoteOperationError(
                category: .session,
                code: "session_lease_released",
                safeDiagnosticMessage: "Remote session lease has already been released"
            )
        }
        return remoteSession
    }

    public func release() async {
        guard !isReleased else { return }
        isReleased = true
        await releaseHandler(id)
    }
}
