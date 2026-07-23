import Foundation
import Testing
@testable import RemoraCore

@Suite("Remote session target binding")
struct RemoteSessionTargetBindingTests {
    @Test("Unbound gateway sessions allow shell but reject target capabilities")
    func unboundGatewayCapabilities() async throws {
        let session = RemoteSession(
            key: unboundSessionKey(),
            transport: ShellOnlySessionTransport()
        )

        let shell = try await session.openShell(pty: PTYSize(columns: 80, rows: 24))
        #expect(await session.activeChannelCount() == 1)
        await shell.close()

        await assertTargetNotResolved {
            _ = try await session.commandExecutor()
        }
        await assertTargetNotResolved {
            _ = try await session.fileSystem()
        }
        await assertTargetNotResolved {
            _ = try await session.administratorFileSystem()
        }
    }

    private func unboundSessionKey() -> RemoteSessionKey {
        RemoteSessionKey(
            route: .gateway(
                GatewayConnectionRoute(
                    providerID: JumpServerGatewayProvider.identifier,
                    endpoint: RemoteEndpoint(hostname: "jump.example.test"),
                    gatewayUsername: "operator",
                    transportUsername: "operator"
                )
            ),
            target: RemoteTargetIdentity(
                savedHostID: UUID(),
                routeProviderID: JumpServerGatewayProvider.identifier,
                assetDisplayName: "JumpServer",
                accountUsername: "",
                bindingState: .unbound
            ),
            authenticationIdentity: RemoteAuthenticationIdentity(
                username: "operator",
                method: .password,
                credentialReference: "password-reference"
            ),
            hostKeyPolicyID: "default"
        )
    }

    private func assertTargetNotResolved(
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected target_not_resolved")
        } catch let error as RemoteOperationError {
            #expect(error.category == .route)
            #expect(error.code == "target_not_resolved")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct ShellOnlySessionTransport: RemoteSessionTransportProtocol {
    func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol {
        ShellOnlyRemoteChannel()
    }

    func close() async {}
}

private actor ShellOnlyRemoteChannel: RemoteShellChannelProtocol {
    nonisolated let id = UUID()

    func start() async throws {}
    func write(_ data: Data) async throws {}
    func resize(_ size: PTYSize) async throws {}
    func events() async -> AsyncThrowingStream<RemoteShellEvent, Error> {
        AsyncThrowingStream { _ in }
    }
    func close() async {}
}
