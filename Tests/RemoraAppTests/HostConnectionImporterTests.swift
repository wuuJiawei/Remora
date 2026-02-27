import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

private actor ProgressEventCollector {
    private var events: [HostConnectionImportProgress] = []

    func append(_ progress: HostConnectionImportProgress) {
        events.append(progress)
    }

    func snapshot() -> [HostConnectionImportProgress] {
        events
    }
}

struct HostConnectionImporterTests {
    @Test
    func importsJSONExportAndRestoresPasswordSecret() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let credentialStore = CredentialStore()
        await credentialStore.setSecret("json-pass", for: "export-pass-1")

        let hosts = [
            Host(
                name: "prod-api",
                address: "10.10.0.5",
                port: 22,
                username: "deploy",
                group: "Production",
                auth: HostAuth(method: .password, passwordReference: "export-pass-1")
            ),
        ]

        let exportURL = try await HostConnectionExporter.export(
            hosts: hosts,
            scope: .all,
            format: .json,
            credentialStore: credentialStore,
            now: Date(timeIntervalSince1970: 0),
            outputDirectoryOverride: tempRoot
        )

        let collector = ProgressEventCollector()
        let imported = try await HostConnectionImporter.importConnections(
            from: exportURL,
            credentialStore: credentialStore,
            progress: { progress in
                Task {
                    await collector.append(progress)
                }
            }
        )

        #expect(imported.count == 1)
        #expect(imported.first?.name == "prod-api")
        #expect(imported.first?.auth.method == .password)
        #expect(imported.first?.auth.passwordReference != nil)
        let restoredRef = imported.first?.auth.passwordReference ?? ""
        let restoredSecret = await credentialStore.secret(for: restoredRef)
        #expect(restoredSecret == "json-pass")
        let progressEvents = await collector.snapshot()
        #expect(progressEvents.contains(where: { $0.phase == "Importing hosts" }))
    }

    @Test
    func importsCSVByAutoDetection() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let csvContent = """
        id,name,address,port,username,group,tags,note,favorite,lastConnectedAt,connectCount,authMethod,privateKeyPath,password,keepAliveSeconds,connectTimeoutSeconds,terminalProfileID
        \(UUID().uuidString),staging-api,10.20.0.12,2222,ops,Staging,api|blue,,true,,4,privateKey,/Users/wuu/.ssh/id_ed25519,,15,8,default
        \(UUID().uuidString),db-admin,10.20.0.20,22,dba,Staging,database,primary,false,,1,password,,csv-pass,30,10,default
        """
        let csvURL = tempRoot.appendingPathComponent("connections.txt")
        try csvContent.data(using: .utf8)?.write(to: csvURL)

        let credentialStore = CredentialStore()
        let imported = try await HostConnectionImporter.importConnections(
            from: csvURL,
            credentialStore: credentialStore
        )

        #expect(imported.count == 2)
        let staging = imported.first(where: { $0.name == "staging-api" })
        #expect(staging?.auth.method == .privateKey)
        #expect(staging?.auth.keyReference == "/Users/wuu/.ssh/id_ed25519")

        let db = imported.first(where: { $0.name == "db-admin" })
        #expect(db?.auth.method == .password)
        let dbPasswordRef = db?.auth.passwordReference ?? ""
        let dbPassword = await credentialStore.secret(for: dbPasswordRef)
        #expect(dbPassword == "csv-pass")
    }
}
