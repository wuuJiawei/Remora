import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct HostConnectionClipboardBuilderTests {
    @Test
    func buildsPasswordConnectionInfoWithoutPasswordValue() async throws {
        let credentialStore = CredentialStore(storage: .isolatedMemory())
        await credentialStore.setSecret("super-secret", for: "pw-1")

        let host = Host(
            name: "prod-api",
            address: "10.0.0.12",
            port: 2222,
            username: "ops",
            group: "Production",
            auth: HostAuth(method: .password, passwordReference: "pw-1")
        )

        let text = try await HostConnectionClipboardBuilder.connectionInfoText(
            for: host,
            includePassword: false,
            credentialStore: credentialStore
        )

        let hostLine = tr("Host") + ": 10.0.0.12"
        let portLine = tr("Port") + ": 2222"
        let usernameLine = tr("Username") + ": ops"
        let authLine = tr("Auth") + ": " + tr("Password")
        let passwordPrefix = tr("Password") + ":"

        #expect(text.contains(hostLine))
        #expect(text.contains(portLine))
        #expect(text.contains(usernameLine))
        #expect(text.contains(authLine))
        #expect(!text.contains(passwordPrefix))
        #expect(!text.contains("super-secret"))
    }

    @Test
    func buildsPasswordConnectionInfoWithPasswordValueWhenExplicitlyIncluded() async throws {
        let credentialStore = CredentialStore(storage: .isolatedMemory())
        await credentialStore.setSecret("super-secret", for: "pw-1")

        let host = Host(
            name: "prod-api",
            address: "10.0.0.12",
            port: 2222,
            username: "ops",
            group: "Production",
            auth: HostAuth(method: .password, passwordReference: "pw-1")
        )

        let text = try await HostConnectionClipboardBuilder.connectionInfoText(
            for: host,
            includePassword: true,
            credentialStore: credentialStore
        )

        let passwordLine = tr("Password") + ": super-secret"
        #expect(text.contains(passwordLine))
    }

    @Test
    func buildsPrivateKeyConnectionInfoWithKeyPath() async throws {
        let host = Host(
            name: "staging",
            address: "10.0.0.20",
            port: 22,
            username: "deploy",
            group: "Staging",
            auth: HostAuth(method: .privateKey, keyReference: "/Users/demo/.ssh/id_ed25519")
        )

        let text = try await HostConnectionClipboardBuilder.connectionInfoText(for: host)
        let authLine = tr("Auth") + ": " + tr("Private Key")
        let keyPathLine = tr("Private Key Path") + ": /Users/demo/.ssh/id_ed25519"
        #expect(text.contains(authLine))
        #expect(text.contains(keyPathLine))
    }

    @Test
    func buildsAgentConnectionInfoWithAgentHint() async throws {
        let host = Host(
            name: "jump",
            address: "10.0.0.30",
            port: 22,
            username: "jump",
            group: "Production",
            auth: HostAuth(method: .agent)
        )

        let text = try await HostConnectionClipboardBuilder.connectionInfoText(for: host)
        let authLine = tr("Auth") + ": " + tr("SSH Agent")
        let credentialLine = tr("Credential") + ": " + tr("Managed by local SSH agent")
        #expect(text.contains(authLine))
        #expect(text.contains(credentialLine))
    }

    @Test
    func buildsSSHCommandWithShellSafeQuoting() throws {
        let host = Host(
            name: "demo",
            address: "example.com; touch /tmp/pwned",
            port: 2200,
            username: "o'reilly",
            auth: HostAuth(method: .agent)
        )

        let command = try HostConnectionClipboardBuilder.sshCommand(for: host)
        #expect(command == "ssh -p 2200 'o'\\''reilly@example.com; touch /tmp/pwned'")
    }

    @Test
    func buildsJumpServerCommandWithProviderTransportUsername() throws {
        let host = Host(
            name: "database via jump",
            address: "jump.example.test",
            port: 2222,
            username: "platform-user",
            auth: HostAuth(method: .password),
            connectionRoute: .gateway(
                GatewayHostRouteConfiguration(
                    providerID: JumpServerGatewayProvider.identifier,
                    platformUsername: "platform-user",
                    target: GatewayTargetConfiguration(
                        assetTarget: "10.0.0.8",
                        assetDisplayName: "Database",
                        accountUsername: "root"
                    )
                )
            )
        )

        let command = try HostConnectionClipboardBuilder.sshCommand(for: host)

        #expect(command == "ssh -p 2222 'platform-user@ssh@root@10.0.0.8@jump.example.test'")
    }

    @Test
    func rejectsInvalidJumpServerCommandInsteadOfFallingBack() {
        let host = Host(
            name: "invalid jump",
            address: "jump.example.test",
            username: "platform-user",
            auth: HostAuth(method: .password),
            connectionRoute: .gateway(
                GatewayHostRouteConfiguration(
                    providerID: JumpServerGatewayProvider.identifier,
                    platformUsername: "invalid@platform"
                )
            )
        )

        #expect(throws: RemoteOperationError.self) {
            _ = try HostConnectionClipboardBuilder.sshCommand(for: host)
        }
    }
}
