import Foundation

public enum NativeSessionCredentialKind: String, Sendable {
    case password
    case privateKeyPassphrase
}

public struct NativeSessionHostKeyChallenge: Identifiable, Sendable {
    public let id: UUID
    public let request: NativeSSHHostKeyTrustRequest

    public init(id: UUID = UUID(), request: NativeSSHHostKeyTrustRequest) {
        self.id = id
        self.request = request
    }
}

public struct NativeSessionCredentialChallenge: Identifiable, Sendable {
    public let id: UUID
    public let kind: NativeSessionCredentialKind

    public init(id: UUID = UUID(), kind: NativeSessionCredentialKind) {
        self.id = id
        self.kind = kind
    }
}

public enum NativeSessionInteractionEvent: Sendable {
    case hostKey(NativeSessionHostKeyChallenge)
    case credential(NativeSessionCredentialChallenge)
    case keyboardInteractive(KeyboardInteractiveChallenge)
}

public final class NativeSessionInteractionBroker: @unchecked Sendable {
    private struct State {
        var hostKeyContinuations: [UUID: CheckedContinuation<NativeSSHHostKeyTrustDecision, Never>] = [:]
        var credentialContinuations: [UUID: CheckedContinuation<String, Error>] = [:]
        var keyboardCoordinators: [UUID: AuthenticationCoordinator] = [:]
        var observationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    }

    private let lock = NSLock()
    private var state = State()
    private let stream: AsyncStream<NativeSessionInteractionEvent>
    private let continuation: AsyncStream<NativeSessionInteractionEvent>.Continuation

    public init() {
        let pair = AsyncStream<NativeSessionInteractionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    deinit {
        cancelPending()
        continuation.finish()
    }

    public func events() -> AsyncStream<NativeSessionInteractionEvent> {
        stream
    }

    public func requestHostKeyDecision(
        for request: NativeSSHHostKeyTrustRequest
    ) async -> NativeSSHHostKeyTrustDecision {
        let challenge = NativeSessionHostKeyChallenge(request: request)
        return await withCheckedContinuation { challengeContinuation in
            lock.withLock {
                state.hostKeyContinuations[challenge.id] = challengeContinuation
            }
            continuation.yield(.hostKey(challenge))
        }
    }

    public func requestCredential(kind: NativeSessionCredentialKind) async throws -> String {
        let challenge = NativeSessionCredentialChallenge(kind: kind)
        return try await withCheckedThrowingContinuation { challengeContinuation in
            lock.withLock {
                state.credentialContinuations[challenge.id] = challengeContinuation
            }
            continuation.yield(.credential(challenge))
        }
    }

    public func observeKeyboardInteractive(_ coordinator: AuthenticationCoordinator) {
        let identifier = ObjectIdentifier(coordinator)
        let shouldStart = lock.withLock {
            guard state.observationTasks[identifier] == nil else { return false }
            state.observationTasks[identifier] = Task { [weak self] in
                guard let self else { return }
                for await challenge in coordinator.challenges() {
                    self.lock.withLock {
                        self.state.keyboardCoordinators[challenge.id] = coordinator
                    }
                    self.continuation.yield(.keyboardInteractive(challenge))
                }
                _ = self.lock.withLock {
                    self.state.observationTasks.removeValue(forKey: identifier)
                }
            }
            return true
        }
        _ = shouldStart
    }

    @discardableResult
    public func respondToHostKey(id: UUID, accept: Bool) -> Bool {
        let pending = lock.withLock {
            state.hostKeyContinuations.removeValue(forKey: id)
        }
        guard let pending else { return false }
        pending.resume(returning: accept ? .accept : .reject)
        return true
    }

    @discardableResult
    public func respondToCredential(id: UUID, value: String) -> Bool {
        let pending = lock.withLock {
            state.credentialContinuations.removeValue(forKey: id)
        }
        guard let pending else { return false }
        pending.resume(returning: value)
        return true
    }

    @discardableResult
    public func respondToKeyboardInteractive(id: UUID, responses: [String]) -> Bool {
        let coordinator = lock.withLock {
            state.keyboardCoordinators.removeValue(forKey: id)
        }
        return coordinator?.respond(to: id, responses: responses) ?? false
    }

    public func cancelPending() {
        let pending = lock.withLock { () -> State in
            let pending = state
            state = State()
            return pending
        }
        pending.hostKeyContinuations.values.forEach { $0.resume(returning: .reject) }
        pending.credentialContinuations.values.forEach {
            $0.resume(throwing: RemoteOperationError(
                category: .authentication,
                code: "credential_request_cancelled",
                safeDiagnosticMessage: "Credential request was cancelled"
            ))
        }
        Set(pending.keyboardCoordinators.values.map(ObjectIdentifier.init))
            .forEach { identifier in
                pending.keyboardCoordinators.values
                    .first(where: { ObjectIdentifier($0) == identifier })?
                    .cancel()
            }
        pending.observationTasks.values.forEach { $0.cancel() }
    }
}
