import Foundation

public struct JumpServerGatewayProvider: GatewayProviderProtocol {
    public static let identifier = "jumpserver"
    private static let maximumComponentBytes = 512
    private static let maximumTransportUsernameBytes = 1_024

    public let providerID = JumpServerGatewayProvider.identifier

    public init() {}

    public func resolve(
        endpoint: RemoteEndpoint,
        savedHostID: UUID,
        savedHostName: String,
        configuration: GatewayHostRouteConfiguration
    ) throws -> ResolvedHostConnectionRoute {
        let platformUsername = try Self.directLoginComponent(
            configuration.platformUsername,
            field: "platform username"
        )

        guard let target = configuration.target else {
            return ResolvedHostConnectionRoute(
                route: .gateway(
                    GatewayConnectionRoute(
                        providerID: providerID,
                        endpoint: endpoint,
                        gatewayUsername: platformUsername,
                        transportUsername: platformUsername
                    )
                ),
                target: RemoteTargetIdentity(
                    savedHostID: savedHostID,
                    routeProviderID: providerID,
                    assetDisplayName: savedHostName,
                    accountUsername: "",
                    connectionProtocol: .ssh,
                    bindingState: .unbound
                )
            )
        }

        guard target.connectionProtocol == .ssh else {
            throw routeError(
                code: "jumpserver_protocol_unsupported",
                message: "JumpServer routes currently support only the SSH protocol"
            )
        }
        let protocolName = try Self.directLoginComponent(
            target.connectionProtocol.rawValue,
            field: "protocol"
        )
        let accountUsername = try Self.directLoginComponent(
            target.accountUsername,
            field: "asset account username"
        )
        let assetTarget = try Self.directLoginComponent(target.assetTarget, field: "asset target")
        let assetDisplayName = try Self.displayValue(
            target.assetDisplayName,
            fallback: assetTarget,
            field: "asset display name"
        )
        let transportUsername = [platformUsername, protocolName, accountUsername, assetTarget]
            .joined(separator: "@")
        guard transportUsername.utf8.count <= Self.maximumTransportUsernameBytes else {
            throw routeError(
                code: "jumpserver_direct_login_too_long",
                message: "JumpServer direct-login username exceeds the supported length"
            )
        }

        return ResolvedHostConnectionRoute(
            route: .gateway(
                GatewayConnectionRoute(
                    providerID: providerID,
                    endpoint: endpoint,
                    gatewayUsername: platformUsername,
                    transportUsername: transportUsername
                )
            ),
            target: RemoteTargetIdentity(
                savedHostID: savedHostID,
                routeProviderID: providerID,
                assetID: Self.normalized(target.assetID) ?? assetTarget,
                assetDisplayName: assetDisplayName,
                accountID: Self.normalized(target.accountID),
                accountUsername: accountUsername,
                connectionProtocol: target.connectionProtocol,
                bindingState: .bound
            )
        )
    }

    public func directLoginUsername(configuration: GatewayHostRouteConfiguration) throws -> String {
        let resolved = try resolve(
            endpoint: RemoteEndpoint(hostname: "validation.invalid"),
            savedHostID: UUID(),
            savedHostName: "JumpServer",
            configuration: configuration
        )
        return resolved.route.transportUsername
    }

    private static func directLoginComponent(_ value: String, field: String) throws -> String {
        guard let value = normalized(value) else {
            throw routeError(
                code: "jumpserver_direct_login_field_missing",
                message: "JumpServer \(field) is required"
            )
        }
        guard value.utf8.count <= maximumComponentBytes,
              !value.contains("@"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw routeError(
                code: "jumpserver_direct_login_field_invalid",
                message: "JumpServer \(field) contains an unsupported delimiter or control character"
            )
        }
        return value
    }

    private static func displayValue(_ value: String, fallback: String, field: String) throws -> String {
        let resolved = normalized(value) ?? fallback
        guard resolved.utf8.count <= maximumComponentBytes,
              !resolved.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw routeError(
                code: "jumpserver_target_display_invalid",
                message: "JumpServer \(field) contains an unsupported control character"
            )
        }
        return resolved
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func routeError(code: String, message: String) -> RemoteOperationError {
        RemoteOperationError(category: .route, code: code, safeDiagnosticMessage: message)
    }

    private func routeError(code: String, message: String) -> RemoteOperationError {
        Self.routeError(code: code, message: message)
    }
}
