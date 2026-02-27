import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct HostConnectionExporterTests {
    @Test
    func exportsJSONWithPlaintextPassword() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let credentialStore = CredentialStore()
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
            credentialStore: credentialStore,
            now: Date(timeIntervalSince1970: 0),
            outputDirectoryOverride: tempRoot
        )

        #expect(outputURL.pathExtension == "json")
        let data = try Data(contentsOf: outputURL)
        let records = try JSONDecoder().decode([HostConnectionExporter.Record].self, from: data)
        #expect(records.count == 1)
        #expect(records.first?.name == "prod-api")
        #expect(records.first?.password == "plain-secret")
        #expect(records.first?.authMethod == AuthenticationMethod.password.rawValue)
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
}
