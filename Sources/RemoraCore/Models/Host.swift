import Foundation

public enum RemoteCommandPrivilege: String, Codable, CaseIterable, Identifiable, Sendable {
    case currentUser
    case sudoNonInteractive

    public var id: String { rawValue }

    public func wrappingShellCommand(_ command: String) -> String {
        switch self {
        case .currentUser:
            return command
        case .sudoNonInteractive:
            let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
            return "sudo -n -- /bin/sh -c '\(escaped)'"
        }
    }
}

public struct HostQuickCommand: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String

    public init(
        id: UUID = UUID(),
        name: String,
        command: String
    ) {
        self.id = id
        self.name = name
        self.command = command
    }
}

public struct HostQuickPath: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String

    public init(
        id: UUID = UUID(),
        name: String,
        path: String
    ) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public enum PortForwardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local

    public var id: String { rawValue }
}

public struct HostPortForwardPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: PortForwardKind
    public var localAddress: String
    public var localPort: Int
    public var remoteAddress: String
    public var remotePort: Int

    public init(
        id: UUID = UUID(),
        name: String,
        kind: PortForwardKind = .local,
        localAddress: String = "127.0.0.1",
        localPort: Int,
        remoteAddress: String,
        remotePort: Int
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }
}

public struct Host: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var group: String
    public var tags: [String]
    public var note: String?
    public var favorite: Bool
    public var lastConnectedAt: Date?
    public var connectCount: Int
    public var auth: HostAuth
    public var remoteCommandPrivilege: RemoteCommandPrivilege
    public var policies: HostPolicies
    public var quickCommands: [HostQuickCommand]
    public var quickPaths: [HostQuickPath]
    public var portForwardPresets: [HostPortForwardPreset]

    public init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: Int = 22,
        username: String,
        group: String = "Default",
        tags: [String] = [],
        note: String? = nil,
        favorite: Bool = false,
        lastConnectedAt: Date? = nil,
        connectCount: Int = 0,
        auth: HostAuth,
        remoteCommandPrivilege: RemoteCommandPrivilege = .currentUser,
        policies: HostPolicies = .init(),
        quickCommands: [HostQuickCommand] = [],
        quickPaths: [HostQuickPath] = [],
        portForwardPresets: [HostPortForwardPreset] = []
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.group = group
        self.tags = tags
        self.note = note
        self.favorite = favorite
        self.lastConnectedAt = lastConnectedAt
        self.connectCount = connectCount
        self.auth = auth
        self.remoteCommandPrivilege = remoteCommandPrivilege
        self.policies = policies
        self.quickCommands = quickCommands
        self.quickPaths = quickPaths
        self.portForwardPresets = portForwardPresets
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case address
        case port
        case username
        case group
        case tags
        case note
        case favorite
        case lastConnectedAt
        case connectCount
        case auth
        case remoteCommandPrivilege
        case policies
        case quickCommands
        case quickPaths
        case portForwardPresets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        group = try container.decode(String.self, forKey: .group)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        connectCount = try container.decodeIfPresent(Int.self, forKey: .connectCount) ?? 0
        auth = try container.decode(HostAuth.self, forKey: .auth)
        remoteCommandPrivilege = try container.decodeIfPresent(
            RemoteCommandPrivilege.self,
            forKey: .remoteCommandPrivilege
        ) ?? .currentUser
        policies = try container.decodeIfPresent(HostPolicies.self, forKey: .policies) ?? .init()
        quickCommands = try container.decodeIfPresent([HostQuickCommand].self, forKey: .quickCommands) ?? []
        quickPaths = try container.decodeIfPresent([HostQuickPath].self, forKey: .quickPaths) ?? []
        portForwardPresets = try container.decodeIfPresent([HostPortForwardPreset].self, forKey: .portForwardPresets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(address, forKey: .address)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(group, forKey: .group)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(favorite, forKey: .favorite)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
        try container.encode(connectCount, forKey: .connectCount)
        try container.encode(auth, forKey: .auth)
        try container.encode(remoteCommandPrivilege, forKey: .remoteCommandPrivilege)
        try container.encode(policies, forKey: .policies)
        try container.encode(quickCommands, forKey: .quickCommands)
        try container.encode(quickPaths, forKey: .quickPaths)
        try container.encode(portForwardPresets, forKey: .portForwardPresets)
    }
}

public struct HostAuth: Codable, Equatable, Sendable {
    public var method: AuthenticationMethod
    public var keyReference: String?
    public var passwordReference: String?

    public init(
        method: AuthenticationMethod,
        keyReference: String? = nil,
        passwordReference: String? = nil
    ) {
        self.method = method
        self.keyReference = keyReference
        self.passwordReference = passwordReference
    }
}

public enum AuthenticationMethod: String, Codable, Sendable {
    case password
    case privateKey
    case agent
}

public struct HostPolicies: Codable, Equatable, Sendable {
    public var keepAliveSeconds: Int
    public var connectTimeoutSeconds: Int
    public var terminalProfileID: String

    public init(
        keepAliveSeconds: Int = 30,
        connectTimeoutSeconds: Int = 10,
        terminalProfileID: String = "default"
    ) {
        self.keepAliveSeconds = keepAliveSeconds
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.terminalProfileID = terminalProfileID
    }
}
