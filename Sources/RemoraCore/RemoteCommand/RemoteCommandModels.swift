import Foundation

public enum RemoteExecutable: Equatable, Sendable {
    case path(String)
    case shell(String)
}

public enum CommandReplayPolicy: Equatable, Sendable {
    case never
    case readOnly
    case idempotent(operationKey: String)

    public func permitsAutomaticRetry(hasProducedOutput: Bool) -> Bool {
        guard !hasProducedOutput else { return false }
        switch self {
        case .never:
            return false
        case .readOnly:
            return true
        case .idempotent(let operationKey):
            return !operationKey.isEmpty
        }
    }
}

public enum RemoteCommandInput: Equatable, Sendable {
    case none
    case data(Data)
}

public struct RemoteCommandRequest: Equatable, Sendable {
    public let id: UUID
    public var executable: RemoteExecutable
    public var arguments: [String]
    public var environment: [String: String]
    public var standardInput: RemoteCommandInput
    public var privilege: RemoteCommandPrivilege
    public var replayPolicy: CommandReplayPolicy
    public var timeout: Duration?

    public init(
        id: UUID = UUID(),
        executable: RemoteExecutable,
        arguments: [String] = [],
        environment: [String: String] = [:],
        standardInput: RemoteCommandInput = .none,
        privilege: RemoteCommandPrivilege = .currentUser,
        replayPolicy: CommandReplayPolicy = .never,
        timeout: Duration? = nil
    ) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.privilege = privilege
        self.replayPolicy = replayPolicy
        self.timeout = timeout
    }
}

public enum RemoteCommandEvent: Equatable, Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case exitStatus(Int32)
}

public struct RemoteCommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let standardOutputWasTruncated: Bool
    public let standardErrorWasTruncated: Bool

    public init(
        exitStatus: Int32,
        standardOutput: Data,
        standardError: Data,
        standardOutputWasTruncated: Bool = false,
        standardErrorWasTruncated: Bool = false
    ) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputWasTruncated = standardOutputWasTruncated
        self.standardErrorWasTruncated = standardErrorWasTruncated
    }
}
