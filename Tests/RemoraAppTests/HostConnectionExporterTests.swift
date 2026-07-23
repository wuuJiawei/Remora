import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct HostConnectionExporterTests {
    @Test
    func exportsJSONWithoutPasswordByDefault() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let credentialStore = CredentialStore(storage: .isolatedMemory())
        await credentialStore.setSecret("plain-secret", for: "pw-ref-1")

        let hosts = [
            Host(
                name: "prod-api",
                address: "10.1.1.1",
                port: 22,
                username: "deploy",
                group: "Production",
                auth: HostAuth(method: .password, passwordReference: "pw-ref-1"),
                remoteCommandPrivilege: .sudoNonInteractive
            ),
        ]

        let outputURL = try await HostConnectionExporter.export(
            hosts: hosts,
            scope: .all,
            format: .json,
            credentialStore: credentialStore,
            now: Date(timeIntervalSince1970: 0),
            outputDirectoryOverride: tempRoot
        )

        #expect(outputURL.pathExtension == "json")
        let data = try Data(contentsOf: outputURL)
        let records = try JSONDecoder().decode([HostConnectionExporter.Record].self, from: data)
        #expect(records.count == 1)
        #expect(records.first?.name == "prod-api")
        #expect(records.first?.password == "")
        #expect(records.first?.authMethod == AuthenticationMethod.password.rawValue)
        #expect(records.first?.remoteCommandPrivilege == RemoteCommandPrivilege.sudoNonInteractive.rawValue)
    }

    @Test
    func exportsJSONWithPasswordOnlyWhenExplicitlyIncluded() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let credentialStore = CredentialStore(storage: .isolatedMemory())
        await credentialStore.setSecret("plain-secret", for: "pw-ref-1")

        let hosts = [
            Host(
                name: "prod-api",
                address: "10.1.1.1",
                port: 22,
                username: "deploy",
                group: "Production",
                auth: HostAuth(method: .password, passwordReference: "pw-ref-1")
            ),
        ]

        let outputURL = try await HostConnectionExporter.export(
            hosts: hosts,
            scope: .all,
            format: .json,
            includeSavedPasswords: true,
            credentialStore: credentialStore,
            now: Date(timeIntervalSince1970: 0),
            outputDirectoryOverride: tempRoot
        )

        let data = try Data(contentsOf: outputURL)
        let records = try JSONDecoder().decode([HostConnectionExporter.Record].self, from: data)
        #expect(records.first?.password == "plain-secret")
    }

    @Test
    func exportsCSVForSingleGroup() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let hosts = [
            Host(
                name: "prod-a",
                address: "10.0.0.1",
                port: 22,
                username: "ops",
                group: "Prod Team",
                auth: HostAuth(method: .agent)
            ),
            Host(
                name: "staging-a",
                address: "10.0.1.1",
                port: 22,
                username: "ops",
                group: "Staging",
                auth: HostAuth(method: .agent)
            ),
        ]

        let outputURL = try await HostConnectionExporter.export(
            hosts: hosts,
            scope: .group("Prod Team"),
            format: .csv,
            now: Date(timeIntervalSince1970: 0),
            outputDirectoryOverride: tempRoot
        )

        #expect(outputURL.pathExtension == "csv")
        #expect(outputURL.lastPathComponent.contains("group-prod-team"))

        let csv = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(csv.contains("prod-a"))
        #expect(!csv.contains("staging-a"))
    }

    @Test
    func exportsJumpServerRouteToJSONAndCSV() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let host = Host(
            name: "database via jump",
            address: "jump.example.test",
            username: "platform-user",
            auth: HostAuth(method: .password),
            connectionRoute: .gateway(
                GatewayHostRouteConfiguration(
                    providerID: JumpServerGatewayProvider.identifier,
                    platformUsername: "platform-user",
                    target: GatewayTargetConfiguration(
                        assetID: "asset-42",
                        assetTarget: "10.0.0.8",
                        assetDisplayName: "Database",
                        accountID: "account-7",
                        accountUsername: "root"
                    )
                )
            )
        )

        let jsonURL = try await HostConnectionExporter.export(
            hosts: [host],
            scope: .all,
            format: .json,
            now: Date(timeIntervalSince1970: 0),
            outputDirectoryOverride: tempRoot
        )
        let records = try JSONDecoder().decode(
            [HostConnectionExporter.Record].self,
            from: Data(contentsOf: jsonURL)
        )
        #expect(records.first?.schemaVersion == HostConnectionExporter.currentSchemaVersion)
        #expect(records.first?.connectionRoute == host.connectionRoute)

        let csvURL = try await HostConnectionExporter.export(
            hosts: [host],
            scope: .all,
            format: .csv,
            now: Date(timeIntervalSince1970: 1),
            outputDirectoryOverride: tempRoot
        )
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("gatewayProviderID"))
        #expect(csv.contains("jumpserver"))
        #expect(csv.contains("asset-42"))
        #expect(!csv.contains("plain-secret"))
    }
}
