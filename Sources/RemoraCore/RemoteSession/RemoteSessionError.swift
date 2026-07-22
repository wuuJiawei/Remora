import Foundation

public enum RemoteErrorCategory: String, Codable, CaseIterable, Sendable {
    case route
    case network
    case hostKey
    case authentication
    case session
    case channel
    case command
    case fileSystem
    case privilege
}

public struct RemoteOperationError: Error, LocalizedError, Equatable, Sendable {
    public let category: RemoteErrorCategory
    public let code: String
    public let safeDiagnosticMessage: String
    public let operationID: UUID?
    public let backendCode: Int?

    public init(
        category: RemoteErrorCategory,
        code: String,
        safeDiagnosticMessage: String,
        operationID: UUID? = nil,
        backendCode: Int? = nil
    ) {
        self.category = category
        self.code = code
        self.safeDiagnosticMessage = safeDiagnosticMessage
        self.operationID = operationID
        self.backendCode = backendCode
    }

    public var errorDescription: String? {
        safeDiagnosticMessage
    }
}

public struct RemoteSessionFailure: Equatable, Sendable {
    public let category: RemoteErrorCategory
    public let code: String

    public init(category: RemoteErrorCategory, code: String) {
        self.category = category
        self.code = code
    }

    public init(_ error: RemoteOperationError) {
        self.init(category: error.category, code: error.code)
    }
}
