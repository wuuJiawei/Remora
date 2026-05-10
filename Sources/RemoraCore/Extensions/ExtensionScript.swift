import Foundation

public enum ExtensionScriptLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case shell
    case python
    case javascript
    case swift

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .shell:
            return "sh"
        case .python:
            return "py"
        case .javascript:
            return "js"
        case .swift:
            return "swift"
        }
    }
}

public enum ExtensionScriptScope: Codable, Equatable, Sendable {
    case global
    case host(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case hostID
    }

    private enum Kind: String, Codable {
        case global
        case host
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .global:
            self = .global
        case .host:
            let hostID = try container.decode(String.self, forKey: .hostID)
            self = .host(hostID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case .host(let hostID):
            try container.encode(Kind.host, forKey: .kind)
            try container.encode(hostID, forKey: .hostID)
        }
    }

    public func applies(to hostID: String?) -> Bool {
        switch self {
        case .global:
            return true
        case .host(let scopedHostID):
            return scopedHostID == hostID
        }
    }
}

public struct ExtensionScript: Codable, Equatable, Identifiable, Sendable {
    public static let defaultTimeoutSeconds = 120
    public static let minimumTimeoutSeconds = 1
    public static let maximumTimeoutSeconds = 3_600

    public let id: UUID
    public var name: String
    public var language: ExtensionScriptLanguage
    public var body: String
    public var scope: ExtensionScriptScope
    public var timeoutSeconds: Int
    public var requireConfirmation: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        language: ExtensionScriptLanguage = .shell,
        body: String,
        scope: ExtensionScriptScope = .global,
        timeoutSeconds: Int = Self.defaultTimeoutSeconds,
        requireConfirmation: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.body = body
        self.scope = scope
        self.timeoutSeconds = Self.clampedTimeoutSeconds(timeoutSeconds)
        self.requireConfirmation = requireConfirmation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEnabled = isEnabled
    }

    public static func clampedTimeoutSeconds(_ value: Int) -> Int {
        min(max(value, minimumTimeoutSeconds), maximumTimeoutSeconds)
    }
}

public enum ExtensionScriptRunStatus: String, Codable, Sendable {
    case success
    case failed
    case timedOut
    case cancelled
    case interpreterMissing
}

public struct ExtensionScriptRunResult: Codable, Equatable, Sendable {
    public var status: ExtensionScriptRunStatus
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String
    public var duration: TimeInterval
    public var errorMessage: String?

    public init(
        status: ExtensionScriptRunStatus,
        exitCode: Int32?,
        stdout: String,
        stderr: String,
        duration: TimeInterval,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
        self.errorMessage = errorMessage
    }
}

public struct ExtensionScriptHostContext: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var host: String?
    public var port: Int?
    public var user: String?
    public var authMethod: String?
    public var keyPath: String?
    public var localDownloadDirectory: String?

    public init(
        id: String? = nil,
        name: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        authMethod: String? = nil,
        keyPath: String? = nil,
        localDownloadDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.authMethod = authMethod
        self.keyPath = keyPath
        self.localDownloadDirectory = localDownloadDirectory
    }
}

public struct ExtensionScriptRunContext: Codable, Equatable, Sendable {
    public var host: ExtensionScriptHostContext?

    public init(host: ExtensionScriptHostContext? = nil) {
        self.host = host
    }
}

public struct ExtensionScriptCollection: Codable, Equatable, Sendable {
    public var scripts: [ExtensionScript]

    public init(scripts: [ExtensionScript] = []) {
        self.scripts = scripts
    }
}
