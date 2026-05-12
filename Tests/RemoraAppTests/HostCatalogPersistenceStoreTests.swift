import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct HostCatalogPersistenceStoreTests {
    @Test
    func saveAndLoadRoundTrip() async throws {
        let baseDirectory = makeTemporaryDirectory()
        defer {
            let root = baseDirectory.deletingLastPathComponent().deletingLastPathComponent()
            try? FileManager.default.removeItem(at: root)
        }

        let store = HostCatalogPersistenceStore(
            baseDirectoryURL: baseDirectory
        )

        let host = Host(
            name: "prod-api",
            address: "10.0.0.10",
            username: "deploy",
            group: "Production",
            tags: ["api"],
            auth: HostAuth(method: .agent),
            portForwardPresets: [
                HostPortForwardPreset(
                    name: "postgres",
                    localAddress: "127.0.0.1",
                    localPort: 5432,
                    remoteAddress: "10.0.0.5",
                    remotePort: 5432
                )
            ]
        )

        let snapshot = PersistedHostCatalog(
            hosts: [host],
            templates: [
                HostSessionTemplate(hostID: host.id, name: "deploy")
            ],
            recentHostIDs: [host.id],
            groups: ["Production"]
        )

        try await store.save(snapshot)
        let loaded = try await store.load()

        #expect(loaded == snapshot)
        #expect(loaded?.hosts.first?.portForwardPresets.count == 1)
    }

    @Test
    func savedPayloadIsPlainJson() async throws {
        let baseDirectory = makeTemporaryDirectory()
        defer {
            let root = baseDirectory.deletingLastPathComponent().deletingLastPathComponent()
            try? FileManager.default.removeItem(at: root)
        }

        let store = HostCatalogPersistenceStore(
            baseDirectoryURL: baseDirectory
        )

        let host = Host(
            name: "internal-db",
            address: "192.168.30.120",
            username: "root",
            group: "LAN",
            tags: ["db"],
            auth: HostAuth(method: .password, passwordReference: "cred-1")
        )

        let snapshot = PersistedHostCatalog(
            hosts: [host],
            templates: [],
            recentHostIDs: [],
            groups: ["LAN"]
        )

        try await store.save(snapshot)

        let fileURL = baseDirectory.appendingPathComponent("connections.json")
        let rawData = try Data(contentsOf: fileURL)
        let rawText = String(decoding: rawData, as: UTF8.self)

        #expect(rawText.contains("internal-db"))
        #expect(rawText.contains("192.168.30.120"))
        #expect(FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent("catalog.key").path) == false)

        let decoded = try JSONDecoder().decode(PersistedHostCatalog.self, from: rawData)
        #expect(decoded == snapshot)
    }

    @Test
    func saveDoesNotCreateCatalogKeySidecar() async throws {
        let baseDirectory = makeTemporaryDirectory()
        defer {
            let root = baseDirectory.deletingLastPathComponent().deletingLastPathComponent()
            try? FileManager.default.removeItem(at: root)
        }

        let host = Host(
            name: "fallback-check",
            address: "172.16.0.8",
            username: "ops",
            group: "Ops",
            tags: [],
            auth: HostAuth(method: .agent)
        )
        let snapshot = PersistedHostCatalog(
            hosts: [host],
            templates: [],
            recentHostIDs: [],
            groups: ["Ops"]
        )

        let store = HostCatalogPersistenceStore(baseDirectoryURL: baseDirectory)

        try await store.save(snapshot)

        let keyFileURL = baseDirectory.appendingPathComponent("catalog.key")
        #expect(FileManager.default.fileExists(atPath: keyFileURL.path) == false)
    }

    private func makeTemporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-host-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(".config/remora", isDirectory: true)
    }
}
