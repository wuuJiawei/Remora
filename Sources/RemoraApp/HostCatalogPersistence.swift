import Foundation
import RemoraCore

struct PersistedHostCatalog: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var hosts: [RemoraCore.Host]
    var templates: [HostSessionTemplate]
    var recentHostIDs: [UUID]
    var groups: [String]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        hosts: [RemoraCore.Host],
        templates: [HostSessionTemplate],
        recentHostIDs: [UUID],
        groups: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.hosts = hosts
        self.templates = templates
        self.recentHostIDs = recentHostIDs
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hosts
        case templates
        case recentHostIDs
        case groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        if let decodedVersion, decodedVersion != Self.currentSchemaVersion {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported host catalog schema version \(decodedVersion)"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        hosts = try container.decode([RemoraCore.Host].self, forKey: .hosts)
        templates = try container.decode([HostSessionTemplate].self, forKey: .templates)
        recentHostIDs = try container.decode([UUID].self, forKey: .recentHostIDs)
        groups = try container.decode([String].self, forKey: .groups)
    }
}

actor HostCatalogPersistenceStore {
    private let storageFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectoryURL: URL = RemoraConfigPaths.rootDirectoryURL()
    ) {
        self.storageFileURL = baseDirectoryURL.appendingPathComponent(RemoraConfigFile.connections.rawValue, isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func load() async throws -> PersistedHostCatalog? {
        guard FileManager.default.fileExists(atPath: storageFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: storageFileURL)
        return try decoder.decode(PersistedHostCatalog.self, from: data)
    }

    func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: storageFileURL.path)
    }

    func save(_ snapshot: PersistedHostCatalog) async throws {
        try FileManager.default.createDirectory(
            at: storageFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: storageFileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageFileURL.path
        )
    }
}
