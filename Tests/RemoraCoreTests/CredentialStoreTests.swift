import Testing
@testable import RemoraCore

struct CredentialStoreTests {
    @Test
    func setGetRemoveSecret() async {
        let store = CredentialStore(storage: .isolatedMemory())

        await store.setSecret("secret-value", for: "api-token")
        let value = await store.secret(for: "api-token")
        #expect(value == "secret-value")

        await store.removeSecret(for: "api-token")
        let afterDelete = await store.secret(for: "api-token")
        #expect(afterDelete == nil)
    }

    @Test
    func secretPersistsAcrossStoreInstances() async {
        let storage = CredentialStoreStorage.isolatedMemory()

        let first = CredentialStore(storage: storage)
        await first.setSecret("db-pass", for: "db-ref")

        let second = CredentialStore(storage: storage)
        let loaded = await second.secret(for: "db-ref")
        #expect(loaded == "db-pass")
    }

    @Test
    func secretUsesInMemoryCacheAfterFirstRead() async {
        let storage = CredentialStoreStorage.isolatedMemory()

        let first = CredentialStore(storage: storage)
        await first.setSecret("cached-pass", for: "cache-ref")

        let second = CredentialStore(storage: storage)
        let initialRead = await second.secret(for: "cache-ref")
        #expect(initialRead == "cached-pass")

        await first.removeSecret(for: "cache-ref")

        let cachedRead = await second.secret(for: "cache-ref")
        #expect(cachedRead == "cached-pass")
    }
}
