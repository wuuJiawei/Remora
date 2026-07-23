import Foundation
import Testing
@testable import RemoraCore

@Suite("JumpServer gateway provider")
struct JumpServerGatewayProviderTests {
    private let provider = JumpServerGatewayProvider()
    private let endpoint = RemoteEndpoint(hostname: "jump.example.test", port: 2222)
    private let hostID = UUID(uuidString: "1B84693A-A7EC-4468-B774-D8ABBD7F0651")!

    @Test("Bound target builds the documented direct-login username")
    func boundTargetBuildsDirectLoginUsername() throws {
        let resolved = try provider.resolve(
            endpoint: endpoint,
            savedHostID: hostID,
            savedHostName: "Production via JumpServer",
            configuration: boundConfiguration()
        )

        #expect(resolved.route.transportUsername == "platform-user@ssh@root@10.0.0.8")
        #expect(resolved.target.bindingState == .bound)
        #expect(resolved.target.routeProviderID == JumpServerGatewayProvider.identifier)
        #expect(resolved.target.assetID == "asset-42")
        #expect(resolved.target.accountID == "account-7")
    }

    @Test("Missing target preserves an interactive gateway shell route")
    func missingTargetBuildsUnboundRoute() throws {
        let resolved = try provider.resolve(
            endpoint: endpoint,
            savedHostID: hostID,
            savedHostName: "JumpServer",
            configuration: GatewayHostRouteConfiguration(
                providerID: JumpServerGatewayProvider.identifier,
                platformUsername: "platform-user"
            )
        )

        #expect(resolved.route.transportUsername == "platform-user")
        #expect(resolved.target.bindingState == .unbound)
        #expect(resolved.target.assetID == nil)
        #expect(resolved.target.accountUsername.isEmpty)
    }

    @Test("Direct-login components reject missing delimiters and control characters")
    func directLoginComponentsAreValidated() {
        assertRouteError(code: "jumpserver_direct_login_field_missing") {
            var configuration = boundConfiguration()
            configuration.target?.accountUsername = "  "
            _ = try provider.resolve(
                endpoint: endpoint,
                savedHostID: hostID,
                savedHostName: "JumpServer",
                configuration: configuration
            )
        }
        assertRouteError(code: "jumpserver_direct_login_field_invalid") {
            var configuration = boundConfiguration()
            configuration.platformUsername = "operator@example"
            _ = try provider.resolve(
                endpoint: endpoint,
                savedHostID: hostID,
                savedHostName: "JumpServer",
                configuration: configuration
            )
        }
        assertRouteError(code: "jumpserver_direct_login_field_invalid") {
            var configuration = boundConfiguration()
            configuration.target?.assetTarget = "10.0.0.8\ninvalid"
            _ = try provider.resolve(
                endpoint: endpoint,
                savedHostID: hostID,
                savedHostName: "JumpServer",
                configuration: configuration
            )
        }
    }

    @Test("Canonical target identity is stable across display-name changes")
    func canonicalTargetIdentityIsStable() throws {
        let first = try provider.resolve(
            endpoint: endpoint,
            savedHostID: hostID,
            savedHostName: "First",
            configuration: boundConfiguration(assetDisplayName: "Database A")
        )
        let second = try provider.resolve(
            endpoint: endpoint,
            savedHostID: hostID,
            savedHostName: "Second",
            configuration: boundConfiguration(assetDisplayName: "Renamed Database")
        )

        #expect(first.target == second.target)
        #expect(first.target.hashValue == second.target.hashValue)
    }

    private func boundConfiguration(
        assetDisplayName: String = "Database"
    ) -> GatewayHostRouteConfiguration {
        GatewayHostRouteConfiguration(
            providerID: JumpServerGatewayProvider.identifier,
            platformUsername: "platform-user",
            target: GatewayTargetConfiguration(
                assetID: "asset-42",
                assetTarget: "10.0.0.8",
                assetDisplayName: assetDisplayName,
                accountID: "account-7",
                accountUsername: "root"
            )
        )
    }

    private func assertRouteError(
        code: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected route error \(code)")
        } catch let error as RemoteOperationError {
            #expect(error.category == .route)
            #expect(error.code == code)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
