import Foundation
import Testing
@testable import RemoraCore

struct HostKeyStoreTests {
    @Test
    func firstSeenThenTrustedThenChanged() async throws {
        let store = HostKeyStore()

        let first = await store.check(host: "example.com", fingerprint: "fp-1")
        #expect(first == .firstSeen)
        try await store.trust(host: "example.com", fingerprint: "fp-1")

        let second = await store.check(host: "example.com", fingerprint: "fp-1")
        #expect(second == .trusted)

        let third = await store.check(host: "example.com", fingerprint: "fp-2")
        #expect(third == .changed(old: "fp-1", new: "fp-2"))
    }
}
