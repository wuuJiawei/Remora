import Foundation

public struct RemoteSessionAcquisitionRequest: Sendable {
    public let key: RemoteSessionKey
    public let createSession: @Sendable () async throws -> any RemoteSessionProtocol

    public init(
        key: RemoteSessionKey,
        createSession: @escaping @Sendable () async throws -> any RemoteSessionProtocol
    ) {
        self.key = key
        self.createSession = createSession
    }
}

public actor RemoteSessionHub {
    public typealias SessionFactory = @Sendable () async throws -> any RemoteSessionProtocol

    private struct Entry {
        let session: any RemoteSessionProtocol
        var leaseIDs: Set<UUID>
    }

    private struct PendingConnection {
        let id: UUID
        let task: Task<any RemoteSessionProtocol, Error>
    }

    private var entries: [RemoteSessionKey: Entry] = [:]
    private var connectionTasks: [RemoteSessionKey: PendingConnection] = [:]

    public init() {}

    public func acquire(
        key: RemoteSessionKey,
        create: @escaping SessionFactory
    ) async throws -> RemoteSessionLease {
        if entries[key] != nil {
            return makeLease(for: key)
        }

        let pending: PendingConnection
        if let existing = connectionTasks[key] {
            pending = existing
        } else {
            let newConnection = PendingConnection(
                id: UUID(),
                task: Task { try await create() }
            )
            connectionTasks[key] = newConnection
            pending = newConnection
        }

        do {
            let session = try await pending.task.value
            guard connectionTasks[key]?.id == pending.id else {
                await session.close()
                throw RemoteOperationError(
                    category: .session,
                    code: "session_acquisition_cancelled",
                    safeDiagnosticMessage: "Remote session acquisition was cancelled"
                )
            }
            connectionTasks.removeValue(forKey: key)
            if entries[key] == nil {
                entries[key] = Entry(session: session, leaseIDs: [])
            } else if entries[key]?.session.id != session.id {
                await session.close()
            }
            return makeLease(for: key)
        } catch {
            if connectionTasks[key]?.id == pending.id {
                connectionTasks.removeValue(forKey: key)
            }
            throw error
        }
    }

    public func acquireExisting(key: RemoteSessionKey) throws -> RemoteSessionLease {
        guard entries[key] != nil else {
            throw RemoteOperationError(
                category: .session,
                code: "session_not_found",
                safeDiagnosticMessage: "No active remote session exists for this target"
            )
        }
        return makeLease(for: key)
    }

    public func snapshot(for key: RemoteSessionKey) async -> RemoteSessionIdentitySnapshot? {
        guard let entry = entries[key] else { return nil }
        return await entry.session.identitySnapshot()
    }

    public func activeSessionCount() -> Int {
        entries.count
    }

    public func activeLeaseCount(for key: RemoteSessionKey) -> Int {
        entries[key]?.leaseIDs.count ?? 0
    }

    public func closeAll() async {
        let tasks = connectionTasks.values.map(\.task)
        connectionTasks.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }

        let sessions = entries.values.map(\.session)
        entries.removeAll(keepingCapacity: false)
        for session in sessions {
            await session.close()
        }
    }

    private func makeLease(for key: RemoteSessionKey) -> RemoteSessionLease {
        precondition(entries[key] != nil)
        let leaseID = UUID()
        entries[key]?.leaseIDs.insert(leaseID)
        let session = entries[key]!.session
        return RemoteSessionLease(id: leaseID, session: session) { [weak self] releasedLeaseID in
            await self?.release(leaseID: releasedLeaseID, for: key)
        }
    }

    private func release(leaseID: UUID, for key: RemoteSessionKey) async {
        guard var entry = entries[key], entry.leaseIDs.remove(leaseID) != nil else { return }
        guard entry.leaseIDs.isEmpty else {
            entries[key] = entry
            return
        }

        entries.removeValue(forKey: key)
        await entry.session.close()
    }
}
