import CryptoKit
import Foundation
import RemoraCore

struct PersistedHostCatalog: Codable, Equatable {
    var hosts: [RemoraCore.Host]
    var templates: [HostSessionTemplate]
    var recentHostIDs: [UUID]
    var groups: [String]
}

struct EncryptedHostCatalogEnvelope: Codable, Equatable {
    var version: Int
    var algorithm: String
    var combined: String
}

enum HostCatalogPersistenceError: LocalizedError {
    case invalidKeyMaterial
    case invalidEncryptedBlob

    var errorDescription: String? {
        switch self {
        case .invalidKeyMaterial:
            return "Invalid key material for host catalog encryption."
        case .invalidEncryptedBlob:
            return "Encrypted host catalog payload is invalid."
        }
    }
}

actor HostCatalogPersistenceStore {
    private let credentialStore: CredentialStore
    private let baseDirectoryURL: URL
    private let storageFileURL: URL
    private let keyFileURL: URL
    private let keyReference: String
    private let usesKeychainForCatalogKey: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedKeyData: Data?
    private var keychainLoadAttempted = false

    init(
        credentialStore: CredentialStore = CredentialStore(),
        keyReference: String = "host-catalog-encryption-key-v1",
        usesKeychainForCatalogKey: Bool = false,
        baseDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".remora/ssh", isDirectory: true)
    ) {
        self.credentialStore = credentialStore
        self.baseDirectoryURL = baseDirectoryURL
        self.storageFileURL = baseDirectoryURL.appendingPathComponent("connections.enc.json")
        self.keyFileURL = baseDirectoryURL.appendingPathComponent("catalog.key")
        self.keyReference = keyReference
        self.usesKeychainForCatalogKey = usesKeychainForCatalogKey

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func load() async throws -> PersistedHostCatalog? {
        guard FileManager.default.fileExists(atPath: storageFileURL.path) else {
            return nil
        }

        let encryptedData = try Data(contentsOf: storageFileURL)
        let envelope = try decoder.decode(EncryptedHostCatalogEnvelope.self, from: encryptedData)
        let plainData = try await decrypt(envelope: envelope)
        return try decoder.decode(PersistedHostCatalog.self, from: plainData)
    }

    func save(_ snapshot: PersistedHostCatalog) async throws {
        try FileManager.default.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        let plainData = try encoder.encode(snapshot)
        let envelope = try await encrypt(plainData: plainData)
        let encryptedData = try encoder.encode(envelope)
        try encryptedData.write(to: storageFileURL, options: [.atomic])
    }

    private func encrypt(plainData: Data) async throws -> EncryptedHostCatalogEnvelope {
        let key = try await encryptionKey()
        let sealedBox = try AES.GCM.seal(plainData, using: key)
        guard let combined = sealedBox.combined else {
            throw HostCatalogPersistenceError.invalidEncryptedBlob
        }

        return EncryptedHostCatalogEnvelope(
            version: 1,
            algorithm: "AES.GCM",
            combined: combined.base64EncodedString()
        )
    }

    private func decrypt(envelope: EncryptedHostCatalogEnvelope) async throws -> Data {
        guard let combinedData = Data(base64Encoded: envelope.combined) else {
            throw HostCatalogPersistenceError.invalidEncryptedBlob
        }

        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        var lastError: Error?
        for key in try await decryptionKeys() {
            do {
                return try AES.GCM.open(sealedBox, using: key)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? HostCatalogPersistenceError.invalidEncryptedBlob
    }

    private func encryptionKey() async throws -> SymmetricKey {
        if let cachedKeyData, cachedKeyData.count == 32 {
            return SymmetricKey(data: cachedKeyData)
        }

        if let fileKeyData = loadKeyDataFromFile() {
            cachedKeyData = fileKeyData
            return SymmetricKey(data: fileKeyData)
        }

        if let keychainData = await loadKeyDataFromKeychainIfNeeded() {
            try persistKeyDataToFile(keychainData)
            cachedKeyData = keychainData
            return SymmetricKey(data: keychainData)
        }

        let generated = SymmetricKey(size: .bits256)
        let keyData = generated.withUnsafeBytes { Data($0) }
        guard keyData.count == 32 else {
            throw HostCatalogPersistenceError.invalidKeyMaterial
        }

        try persistKeyDataToFile(keyData)
        cachedKeyData = keyData
        return generated
    }

    private func decryptionKeys() async throws -> [SymmetricKey] {
        if let cachedKeyData, cachedKeyData.count == 32 {
            return [SymmetricKey(data: cachedKeyData)]
        }

        if let fileData = loadKeyDataFromFile() {
            cachedKeyData = fileData
            return [SymmetricKey(data: fileData)]
        }

        if let keychainData = await loadKeyDataFromKeychainIfNeeded() {
            cachedKeyData = keychainData
            return [SymmetricKey(data: keychainData)]
        }

        return [try await encryptionKey()]
    }

    private func loadKeyDataFromKeychainIfNeeded() async -> Data? {
        guard usesKeychainForCatalogKey else { return nil }
        guard !keychainLoadAttempted else { return nil }
        keychainLoadAttempted = true
        guard let base64 = await credentialStore.secret(for: keyReference),
              let keyData = Data(base64Encoded: base64),
              keyData.count == 32
        else {
            return nil
        }
        return keyData
    }

    private func loadKeyDataFromFile() -> Data? {
        guard let raw = try? Data(contentsOf: keyFileURL),
              let base64 = String(data: raw, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let keyData = Data(base64Encoded: base64),
              keyData.count == 32
        else {
            return nil
        }
        return keyData
    }

    private func persistKeyDataToFile(_ keyData: Data) throws {
        guard keyData.count == 32 else {
            throw HostCatalogPersistenceError.invalidKeyMaterial
        }
        try FileManager.default.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        guard let encoded = keyData.base64EncodedString().data(using: .utf8) else {
            throw HostCatalogPersistenceError.invalidKeyMaterial
        }
        try encoded.write(to: keyFileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyFileURL.path
        )
    }
}
