import Foundation

public struct GatewayTargetConfiguration: Codable, Equatable, Sendable {
    public var assetID: String?
    public var assetTarget: String
    public var assetDisplayName: String
    public var accountID: String?
    public var accountUsername: String
    public var connectionProtocol: RemoteConnectionProtocol

    public init(
        assetID: String? = nil,
        assetTarget: String,
        assetDisplayName: String,
        accountID: String? = nil,
        accountUsername: String,
        connectionProtocol: RemoteConnectionProtocol = .ssh
    ) {
        self.assetID = assetID
        self.assetTarget = assetTarget
        self.assetDisplayName = assetDisplayName
        self.accountID = accountID
        self.accountUsername = accountUsername
        self.connectionProtocol = connectionProtocol
    }
}

public struct GatewayHostRouteConfiguration: Codable, Equatable, Sendable {
    public var providerID: String
    public var platformUsername: String
    public var target: GatewayTargetConfiguration?

    public init(
        providerID: String,
        platformUsername: String,
        target: GatewayTargetConfiguration? = nil
    ) {
        self.providerID = providerID
        self.platformUsername = platformUsername
        self.target = target
    }
}

public enum HostConnectionRouteConfiguration: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    case direct
    case gateway(GatewayHostRouteConfiguration)

    public var isTargetBound: Bool {
        switch self {
        case .direct:
            return true
        case .gateway(let configuration):
            return configuration.target != nil
        }
    }
}

extension HostConnectionRouteConfiguration: Codable {
    private enum Kind: String, Codable {
        case direct
        case gateway
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case gateway
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported host route schema version \(schemaVersion)"
            )
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .direct:
            self = .direct
        case .gateway:
            self = .gateway(try container.decode(GatewayHostRouteConfiguration.self, forKey: .gateway))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        switch self {
        case .direct:
            try container.encode(Kind.direct, forKey: .kind)
        case .gateway(let configuration):
            try container.encode(Kind.gateway, forKey: .kind)
            try container.encode(configuration, forKey: .gateway)
        }
    }
}

public struct ResolvedHostConnectionRoute: Sendable {
    public let route: ConnectionRoute
    public let target: RemoteTargetIdentity

    public init(route: ConnectionRoute, target: RemoteTargetIdentity) {
        self.route = route
        self.target = target
    }
}

public protocol GatewayProviderProtocol: Sendable {
    var providerID: String { get }

    func resolve(
        endpoint: RemoteEndpoint,
        savedHostID: UUID,
        savedHostName: String,
        configuration: GatewayHostRouteConfiguration
    ) throws -> ResolvedHostConnectionRoute
}

public struct GatewayProviderRegistry: Sendable {
    private let providers: [String: any GatewayProviderProtocol]

    public init(providers: [any GatewayProviderProtocol] = [JumpServerGatewayProvider()]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.providerID, $0) })
    }

    public func resolve(
        endpoint: RemoteEndpoint,
        savedHostID: UUID,
        savedHostName: String,
        configuration: GatewayHostRouteConfiguration
    ) throws -> ResolvedHostConnectionRoute {
        guard let provider = providers[configuration.providerID] else {
            throw RemoteOperationError(
                category: .route,
                code: "gateway_provider_unsupported",
                safeDiagnosticMessage: "The configured gateway provider is not supported"
            )
        }
        return try provider.resolve(
            endpoint: endpoint,
            savedHostID: savedHostID,
            savedHostName: savedHostName,
            configuration: configuration
        )
    }
}

public struct HostConnectionRouteResolver: Sendable {
    private let gatewayProviders: GatewayProviderRegistry

    public init(gatewayProviders: GatewayProviderRegistry = GatewayProviderRegistry()) {
        self.gatewayProviders = gatewayProviders
    }

    public func resolve(host: Host) throws -> ResolvedHostConnectionRoute {
        let endpoint = RemoteEndpoint(hostname: host.address, port: host.port)
        switch host.connectionRoute {
        case .direct:
            return ResolvedHostConnectionRoute(
                route: .direct(DirectConnectionRoute(endpoint: endpoint, username: host.username)),
                target: RemoteTargetIdentity(
                    savedHostID: host.id,
                    routeProviderID: "direct",
                    assetID: host.id.uuidString,
                    assetDisplayName: host.name,
                    accountID: host.username,
                    accountUsername: host.username,
                    connectionProtocol: .ssh,
                    bindingState: .bound
                )
            )
        case .gateway(let configuration):
            return try gatewayProviders.resolve(
                endpoint: endpoint,
                savedHostID: host.id,
                savedHostName: host.name,
                configuration: configuration
            )
        }
    }
}
