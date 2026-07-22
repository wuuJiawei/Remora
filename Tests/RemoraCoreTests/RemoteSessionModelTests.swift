import Foundation
import Testing
@testable import RemoraCore

@Suite("Remote session models")
struct RemoteSessionModelTests {
    @Test("Session keys distinguish gateway targets")
    func sessionKeysDistinguishGatewayTargets() {
        let hostID = UUID()
        let route = ConnectionRoute.gateway(
            GatewayConnectionRoute(
                providerID: "jumpserver",
                endpoint: RemoteEndpoint(hostname: "gateway.example.com"),
                gatewayUsername: "platform-user",
                transportUsername: "platform-user@ssh@root@asset-a"
            )
        )
        let authentication = RemoteAuthenticationIdentity(
            username: "platform-user",
            method: .password,
            credentialReference: "credential"
        )
        let first = RemoteSessionKey(
            route: route,
            target: RemoteTargetIdentity(
                savedHostID: hostID,
                routeProviderID: "jumpserver",
                assetID: "asset-a",
                assetDisplayName: "Asset A",
                accountUsername: "root"
            ),
            authenticationIdentity: authentication,
            hostKeyPolicyID: "default"
        )
        let second = RemoteSessionKey(
            route: route,
            target: RemoteTargetIdentity(
                savedHostID: hostID,
                routeProviderID: "jumpserver",
                assetID: "asset-b",
                assetDisplayName: "Asset B",
                accountUsername: "root"
            ),
            authenticationIdentity: authentication,
            hostKeyPolicyID: "default"
        )

        #expect(first != second)
    }

    @Test("Target display names do not change runtime identity")
    func targetDisplayNamesDoNotChangeRuntimeIdentity() {
        let hostID = UUID()
        let first = RemoteTargetIdentity(
            savedHostID: hostID,
            routeProviderID: "jumpserver",
            assetID: "asset-a",
            assetDisplayName: "Old name",
            accountUsername: "root"
        )
        let renamed = RemoteTargetIdentity(
            savedHostID: hostID,
            routeProviderID: "jumpserver",
            assetID: "asset-a",
            assetDisplayName: "New name",
            accountUsername: "root"
        )

        #expect(first == renamed)
        #expect(first.hashValue == renamed.hashValue)
    }

    @Test("State machine rejects skipped authentication")
    func stateMachineRejectsSkippedAuthentication() throws {
        var machine = RemoteSessionStateMachine()
        try machine.transition(to: .connecting)

        #expect(throws: RemoteSessionStateTransitionError(from: .connecting, to: .ready)) {
            try machine.transition(to: .ready)
        }
    }

    @Test("Native context close is deterministic")
    func nativeContextCloseIsDeterministic() throws {
        #expect(NativeSSHContext.nativeABIVersion == NativeSSHContext.expectedABIVersion)
        let context = try NativeSSHContext()
        #expect(context.isOpen)
        context.close()
        context.close()
        #expect(!context.isOpen)
        #expect(throws: NativeSSHContextError.closed) {
            try context.requireOpen()
        }
    }
}
