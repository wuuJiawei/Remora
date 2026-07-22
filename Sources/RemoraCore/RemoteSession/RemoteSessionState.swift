import Foundation

public enum RemoteSessionPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case connecting
    case awaitingHostKey
    case authenticating
    case ready
    case reconnecting
    case failed
    case closing
    case closed
}

public enum RemoteSessionState: Equatable, Sendable {
    case idle
    case connecting
    case awaitingHostKey
    case authenticating
    case ready
    case reconnecting(attempt: Int)
    case failed(RemoteSessionFailure)
    case closing
    case closed

    public var phase: RemoteSessionPhase {
        switch self {
        case .idle: .idle
        case .connecting: .connecting
        case .awaitingHostKey: .awaitingHostKey
        case .authenticating: .authenticating
        case .ready: .ready
        case .reconnecting: .reconnecting
        case .failed: .failed
        case .closing: .closing
        case .closed: .closed
        }
    }
}

public struct RemoteSessionStateTransitionError: Error, Equatable, Sendable {
    public let from: RemoteSessionPhase
    public let to: RemoteSessionPhase

    public init(from: RemoteSessionPhase, to: RemoteSessionPhase) {
        self.from = from
        self.to = to
    }
}

public struct RemoteSessionStateMachine: Sendable {
    public private(set) var state: RemoteSessionState

    public init(initialState: RemoteSessionState = .idle) {
        state = initialState
    }

    public mutating func transition(to newState: RemoteSessionState) throws {
        guard Self.allowsTransition(from: state.phase, to: newState.phase) else {
            throw RemoteSessionStateTransitionError(from: state.phase, to: newState.phase)
        }
        state = newState
    }

    public static func allowsTransition(
        from current: RemoteSessionPhase,
        to next: RemoteSessionPhase
    ) -> Bool {
        if next == .closing, current != .closed, current != .closing {
            return true
        }

        switch (current, next) {
        case (.idle, .connecting),
             (.connecting, .awaitingHostKey),
             (.awaitingHostKey, .authenticating),
             (.authenticating, .ready),
             (.ready, .reconnecting),
             (.reconnecting, .ready),
             (.closing, .closed):
            return true
        case (.connecting, .failed),
             (.awaitingHostKey, .failed),
             (.authenticating, .failed),
             (.ready, .failed),
             (.reconnecting, .failed):
            return true
        default:
            return false
        }
    }
}
