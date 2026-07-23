import Foundation
import Security

public enum CredentialStoreStorage: Sendable {
    case applicationKeychain
    case memory(namespace: String)

    public static func isolatedMemory() -> CredentialStoreStorage {
        .memory(namespace: UUID().uuidString)
    }
}

public actor CredentialStore {
    private struct LegacyCredentialFilePayload: Codable {
        var version: Int
        var values: [String: String]
    }

    private let backend: any CredentialStoreBackend
    private let legacyFileURL: URL?
    private var legacyValues: [String: String]
    private var inMemoryStorage: [String: String] = [:]

    public init(
        storage: CredentialStoreStorage = .applicationKeychain,
        legacyBaseDirectoryURL: URL = RemoraConfigPaths.rootDirectoryURL()
    ) {
        let resolvedBackend: any CredentialStoreBackend
        let resolvedLegacyFileURL: URL?
        switch storage {
        case .applicationKeychain:
            resolvedBackend = KeychainCredentialStoreBackend(service: "io.lighting-tech.remora.credentials")
            resolvedLegacyFileURL = legacyBaseDirectoryURL.appendingPathComponent(
                RemoraConfigFile.credentials.rawValue,
                isDirectory: false
            )
        case .memory(let namespace):
            resolvedBackend = MemoryCredentialStoreBackend(namespace: namespace)
            resolvedLegacyFileURL = nil
        }

        var resolvedLegacyValues = Self.loadLegacyValues(from: resolvedLegacyFileURL)
        if !resolvedLegacyValues.isEmpty,
           resolvedLegacyValues.allSatisfy({ resolvedBackend.set($0.value, for: $0.key) }) {
            if let resolvedLegacyFileURL {
                try? FileManager.default.removeItem(at: resolvedLegacyFileURL)
            }
            resolvedLegacyValues.removeAll(keepingCapacity: false)
        }

        backend = resolvedBackend
        legacyFileURL = resolvedLegacyFileURL
        legacyValues = resolvedLegacyValues
    }

    public func setSecret(_ value: String, for key: String) async {
        guard !key.isEmpty else { return }
        if backend.set(value, for: key) {
            inMemoryStorage[key] = value
            if legacyValues.removeValue(forKey: key) != nil {
                persistRemainingLegacyValues()
            }
        }
    }

    public func secret(for key: String) async -> String? {
        guard !key.isEmpty else { return nil }
        if let value = inMemoryStorage[key] {
            return value
        }
        if let value = backend.value(for: key) {
            inMemoryStorage[key] = value
            return value
        }
        if let value = legacyValues[key] {
            return value
        }
        return nil
    }

    public func removeSecret(for key: String) async {
        guard !key.isEmpty else { return }
        inMemoryStorage.removeValue(forKey: key)
        legacyValues.removeValue(forKey: key)
        _ = backend.removeValue(for: key)
        persistRemainingLegacyValues()
    }

    private func persistRemainingLegacyValues() {
        guard let legacyFileURL else { return }
        guard !legacyValues.isEmpty else {
            try? FileManager.default.removeItem(at: legacyFileURL)
            return
        }
        let store = RemoraJSONFileStore<LegacyCredentialFilePayload>(
            fileURL: legacyFileURL,
            outputFormatting: [.sortedKeys]
        )
        try? store.save(LegacyCredentialFilePayload(version: 1, values: legacyValues))
    }

    private static func loadLegacyValues(from fileURL: URL?) -> [String: String] {
        guard let fileURL else { return [:] }
        let store = RemoraJSONFileStore<LegacyCredentialFilePayload>(fileURL: fileURL)
        return (try? store.load())?.values ?? [:]
    }
}

private protocol CredentialStoreBackend: Sendable {
    func set(_ value: String, for key: String) -> Bool
    func value(for key: String) -> String?
    func removeValue(for key: String) -> Bool
}

private final class KeychainCredentialStoreBackend: CredentialStoreBackend, @unchecked Sendable {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    func value(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func removeValue(for key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

private final class MemoryCredentialStoreBackend: CredentialStoreBackend, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var valuesByNamespace: [String: [String: String]] = [:]
    }

    private static let state = State()

    private let namespace: String

    init(namespace: String) {
        self.namespace = namespace
    }

    func set(_ value: String, for key: String) -> Bool {
        Self.state.lock.withLock {
            Self.state.valuesByNamespace[namespace, default: [:]][key] = value
        }
        return true
    }

    func value(for key: String) -> String? {
        Self.state.lock.withLock {
            Self.state.valuesByNamespace[namespace]?[key]
        }
    }

    func removeValue(for key: String) -> Bool {
        Self.state.lock.withLock {
            Self.state.valuesByNamespace[namespace]?.removeValue(forKey: key)
            if Self.state.valuesByNamespace[namespace]?.isEmpty == true {
                Self.state.valuesByNamespace.removeValue(forKey: namespace)
            }
        }
        return true
    }
}
