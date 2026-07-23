import Foundation

public enum RemoteConnectionProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh

    public var id: String { rawValue }
}

public enum RemoteTargetBindingState: String, Codable, Hashable, Sendable {
    case bound
    case unbound
}

public struct RemoteEndpoint: Codable, Hashable, Sendable {
    public let hostname: String
    public let port: Int

    public init(hostname: String, port: Int = 22) {
        self.hostname = hostname
        self.port = port
    }
}

public struct RemoteTargetIdentity: Codable, Hashable, Sendable {
    public let savedHostID: UUID
    public let routeProviderID: String
    public let assetID: String?
    public let assetDisplayName: String
    public let accountID: String?
    public let accountUsername: String
    public let connectionProtocol: RemoteConnectionProtocol
    public let bindingState: RemoteTargetBindingState

    public init(
        savedHostID: UUID,
        routeProviderID: String,
        assetID: String? = nil,
        assetDisplayName: String,
        accountID: String? = nil,
        accountUsername: String,
        connectionProtocol: RemoteConnectionProtocol = .ssh,
        bindingState: RemoteTargetBindingState = .bound
    ) {
        self.savedHostID = savedHostID
        self.routeProviderID = routeProviderID
        self.assetID = assetID
        self.assetDisplayName = assetDisplayName
        self.accountID = accountID
        self.accountUsername = accountUsername
        self.connectionProtocol = connectionProtocol
        self.bindingState = bindingState
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.savedHostID == rhs.savedHostID
            && lhs.routeProviderID == rhs.routeProviderID
            && lhs.assetID == rhs.assetID
            && lhs.accountID == rhs.accountID
            && lhs.accountUsername == rhs.accountUsername
            && lhs.connectionProtocol == rhs.connectionProtocol
            && lhs.bindingState == rhs.bindingState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(savedHostID)
        hasher.combine(routeProviderID)
        hasher.combine(assetID)
        hasher.combine(accountID)
        hasher.combine(accountUsername)
        hasher.combine(connectionProtocol)
        hasher.combine(bindingState)
    }
}

public struct DirectConnectionRoute: Hashable, Sendable {
    public let endpoint: RemoteEndpoint
    public let username: String

    public init(endpoint: RemoteEndpoint, username: String) {
        self.endpoint = endpoint
        self.username = username
    }
}

public struct GatewayConnectionRoute: Hashable, Sendable {
    public let providerID: String
    public let endpoint: RemoteEndpoint
    public let gatewayUsername: String
    public let transportUsername: String

    public init(
        providerID: String,
        endpoint: RemoteEndpoint,
        gatewayUsername: String,
        transportUsername: String
    ) {
        self.providerID = providerID
        self.endpoint = endpoint
        self.gatewayUsername = gatewayUsername
        self.transportUsername = transportUsername
    }
}

public enum ConnectionRoute: Hashable, Sendable {
    case direct(DirectConnectionRoute)
    case gateway(GatewayConnectionRoute)

    public var endpoint: RemoteEndpoint {
        switch self {
        case .direct(let route):
            return route.endpoint
        case .gateway(let route):
            return route.endpoint
        }
    }

    public var transportUsername: String {
        switch self {
        case .direct(let route):
            return route.username
        case .gateway(let route):
            return route.transportUsername
        }
    }
}

public struct RemoteAuthenticationIdentity: Hashable, Sendable {
    public let username: String
    public let method: AuthenticationMethod
    public let credentialReference: String?

    public init(
        username: String,
        method: AuthenticationMethod,
        credentialReference: String? = nil
    ) {
        self.username = username
        self.method = method
        self.credentialReference = credentialReference
    }
}

public struct RemoteSessionKey: Hashable, Sendable {
    public let route: ConnectionRoute
    public let target: RemoteTargetIdentity
    public let authenticationIdentity: RemoteAuthenticationIdentity
    public let hostKeyPolicyID: String

    public init(
        route: ConnectionRoute,
        target: RemoteTargetIdentity,
        authenticationIdentity: RemoteAuthenticationIdentity,
        hostKeyPolicyID: String
    ) {
        self.route = route
        self.target = target
        self.authenticationIdentity = authenticationIdentity
        self.hostKeyPolicyID = hostKeyPolicyID
    }
}
