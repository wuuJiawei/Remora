import Foundation
import Testing
@testable import RemoraCore

struct ConfigPathTests {
    private struct SamplePayload: Codable, Equatable {
        var value: String
    }

    @Test
    func configRootUsesDotConfigRemoraUnderProvidedHome() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-config-home-\(UUID().uuidString)", isDirectory: true)

        let root = RemoraConfigPaths.rootDirectoryURL(homeDirectoryURL: home)

        #expect(root == home.appendingPathComponent(".config/remora", isDirectory: true))
    }

    @Test
    func knownConfigFilesResolveInsideConfigRoot() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-config-home-\(UUID().uuidString)", isDirectory: true)

        #expect(
            RemoraConfigPaths.fileURL(for: .credentials, homeDirectoryURL: home)
                == home.appendingPathComponent(".config/remora/credentials.json", isDirectory: false)
        )
        #expect(
            RemoraConfigPaths.fileURL(for: .connections, homeDirectoryURL: home)
                == home.appendingPathComponent(".config/remora/connections.json", isDirectory: false)
        )
        #expect(
            RemoraConfigPaths.fileURL(for: .settings, homeDirectoryURL: home)
                == home.appendingPathComponent(".config/remora/settings.json", isDirectory: false)
        )
    }

    @Test
    func jsonFileStorePersistsPayloadAndCreatesParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-json-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("nested/config.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = RemoraJSONFileStore<SamplePayload>(fileURL: fileURL)
        try store.save(SamplePayload(value: "hello"))

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try store.load() == SamplePayload(value: "hello"))
    }

    @Test
    func jsonFileStoreReturnsNilForMissingFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-json-store-missing-\(UUID().uuidString).json", isDirectory: false)
        let store = RemoraJSONFileStore<SamplePayload>(fileURL: fileURL)

        #expect(try store.load() == nil)
    }
}
