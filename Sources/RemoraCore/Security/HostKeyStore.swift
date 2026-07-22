import Foundation

public enum HostKeyValidationResult: Equatable, Sendable {
    case trusted
    case firstSeen
    case changed(old: String, new: String)
}

public actor HostKeyStore {
    private struct Payload: Codable {
        let version: Int
        var fingerprints: [String: String]

        init(version: Int = 1, fingerprints: [String: String]) {
            self.version = version
            self.fingerprints = fingerprints
        }
    }

    private let fileStore: RemoraJSONFileStore<Payload>?
    private var fingerprints: [String: String]

    public init() {
        fileStore = nil
        fingerprints = [:]
    }

    public init(
        baseDirectoryURL: URL,
        filename: String = RemoraConfigFile.hostKeys.rawValue
    ) throws {
        let store = RemoraJSONFileStore<Payload>(
            fileURL: baseDirectoryURL.appendingPathComponent(filename, isDirectory: false),
            outputFormatting: [.prettyPrinted, .sortedKeys]
        )
        fileStore = store
        fingerprints = try store.load()?.fingerprints ?? [:]
    }

    public static func persistent(
        baseDirectoryURL: URL = RemoraConfigPaths.rootDirectoryURL()
    ) throws -> HostKeyStore {
        try HostKeyStore(baseDirectoryURL: baseDirectoryURL)
    }

    public func check(host: String, fingerprint: String) -> HostKeyValidationResult {
        guard let existing = fingerprints[host] else { return .firstSeen }
        return existing == fingerprint
            ? .trusted
            : .changed(old: existing, new: fingerprint)
    }

    public func trust(host: String, fingerprint: String) throws {
        var updated = fingerprints
        updated[host] = fingerprint
        if let fileStore {
            try fileStore.save(Payload(fingerprints: updated))
        }
        fingerprints = updated
    }
}
