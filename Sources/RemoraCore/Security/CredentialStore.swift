import Foundation
import Security

public actor CredentialStore {
    private actor SharedMemoryCache {
        private var values: [String: String] = [:]

        func set(_ value: String, for key: String) {
            values[key] = value
        }

        func value(for key: String) -> String? {
            values[key]
        }

        func remove(for key: String) {
            values.removeValue(forKey: key)
        }
    }

    private static let sharedCache = SharedMemoryCache()
    private let service = "io.lighting-tech.remora.credentials"
    private var inMemoryStorage: [String: String] = [:]

    public init() {}

    public func setSecret(_ value: String, for key: String) async {
        inMemoryStorage[key] = value
        await Self.sharedCache.set(value, for: key)
        _ = saveToKeychain(value, for: key)
    }

    public func secret(for key: String) async -> String? {
        if let value = inMemoryStorage[key] {
            return value
        }

        if let cached = await Self.sharedCache.value(for: key) {
            inMemoryStorage[key] = cached
            return cached
        }

        if let value = readFromKeychain(for: key) {
            inMemoryStorage[key] = value
            await Self.sharedCache.set(value, for: key)
            return value
        }
        return nil
    }

    public func removeSecret(for key: String) async {
        inMemoryStorage.removeValue(forKey: key)
        await Self.sharedCache.remove(for: key)
        deleteFromKeychain(for: key)
    }

    @discardableResult
    private func saveToKeychain(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    private func readFromKeychain(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
