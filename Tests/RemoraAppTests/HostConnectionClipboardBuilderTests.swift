import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct HostConnectionClipboardBuilderTests {
    @Test
    func buildsPasswordConnectionInfoWithPlaintextPassword() async {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-clipboard-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let credentialStore = CredentialStore(
            baseDirectoryURL: tempRoot,
            credentialsFilename: "credentials.json"
        )
        await credentialStore.setSecret("super-secret", for: "pw-1")

        let host = Host(
            name: "prod-api",
            address: "10.0.0.12",
            port: 2222,
            username: "ops",
            group: "Production",
            auth: HostAuth(method: .password, passwordReference: "pw-1")
        )

        let text = await HostConnectionClipboardBuilder.connectionInfoText(
            for: host,
            credentialStore: credentialStore
        )

        #expect(text.contains("Host: 10.0.0.12"))
        #expect(text.contains("Port: 2222"))
        #expect(text.contains("Username: ops"))
        #expect(text.contains("Auth: Password"))
        #expect(text.contains("Password: super-secret"))
    }

    @Test
    func buildsPrivateKeyConnectionInfoWithKeyPath() async {
        let host = Host(
            name: "staging",
            address: "10.0.0.20",
            port: 22,
            username: "deploy",
            group: "Staging",
            auth: HostAuth(method: .privateKey, keyReference: "/Users/demo/.ssh/id_ed25519")
        )

        let text = await HostConnectionClipboardBuilder.connectionInfoText(for: host)
        #expect(text.contains("Auth: Private Key"))
        #expect(text.contains("Private Key Path: /Users/demo/.ssh/id_ed25519"))
    }

    @Test
    func buildsAgentConnectionInfoWithAgentHint() async {
        let host = Host(
            name: "jump",
            address: "10.0.0.30",
            port: 22,
            username: "jump",
            group: "Production",
            auth: HostAuth(method: .agent)
        )

        let text = await HostConnectionClipboardBuilder.connectionInfoText(for: host)
        #expect(text.contains("Auth: SSH Agent"))
        #expect(text.contains("Credential: Managed by local SSH agent"))
    }

    @Test
    func buildsSSHCommand() {
        let host = Host(
            name: "demo",
            address: "1.2.3.4",
            port: 2200,
            username: "root",
            auth: HostAuth(method: .agent)
        )

        let command = HostConnectionClipboardBuilder.sshCommand(for: host)
        #expect(command == "ssh root@1.2.3.4 -p 2200")
    }
}
