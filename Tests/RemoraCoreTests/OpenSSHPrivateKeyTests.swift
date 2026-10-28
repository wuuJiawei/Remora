import CryptoKit
import Foundation
import Testing
@testable import RemoraCore

@Suite("OpenSSH Ed25519 private key import")
struct OpenSSHPrivateKeyTests {
    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/OpenSSHKeys", isDirectory: true)
    private static let passphrase = "remora-test-pass"

    private static func fixture(_ name: String) -> URL {
        fixtureDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private static func publicKeyBlob(named name: String) throws -> Data {
        let text = try String(contentsOf: fixture(name), encoding: .utf8)
        let fields = text.split(separator: " ")
        try #require(fields.count >= 2)
        return try #require(Data(base64Encoded: String(fields[1])))
    }

    private static func expectSignature(_ privateKey: OpenSSHEd25519PrivateKey) throws {
        let payload = Data("remora-ed25519-test-payload".utf8)
        let signature = try #require(privateKey.signature(for: payload))
        #expect(signature.count == 64)

        let publicKeyData = try #require(
            SSHKeyWire.ed25519PublicKey(in: [UInt8](privateKey.publicKeyBlob))
        )
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        #expect(publicKey.isValidSignature(signature, for: payload))
    }

    @Test
    func importsUnencryptedKey() throws {
        let privateKey = try #require(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ed25519_unencrypted"),
                passphrase: nil
            )
        )
        #expect(
            privateKey.publicKeyBlob
                == (try Self.publicKeyBlob(named: "ed25519_unencrypted.pub"))
        )
        try Self.expectSignature(privateKey)
    }

    @Test
    func importsAES128CTRKey() throws {
        let privateKey = try #require(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ed25519_aes128ctr"),
                passphrase: Self.passphrase
            )
        )
        #expect(
            privateKey.publicKeyBlob
                == (try Self.publicKeyBlob(named: "ed25519_aes128ctr.pub"))
        )
        try Self.expectSignature(privateKey)
    }

    @Test
    func importsAES256CTRKey() throws {
        let privateKey = try #require(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ed25519_aes256ctr"),
                passphrase: Self.passphrase
            )
        )
        #expect(
            privateKey.publicKeyBlob
                == (try Self.publicKeyBlob(named: "ed25519_aes256ctr.pub"))
        )
        try Self.expectSignature(privateKey)
    }

    @Test
    func importsAES192CTRKey() throws {
        let privateKey = try #require(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ed25519_aes192ctr"),
                passphrase: Self.passphrase
            )
        )
        #expect(
            privateKey.publicKeyBlob
                == (try Self.publicKeyBlob(named: "ed25519_aes192ctr.pub"))
        )
        try Self.expectSignature(privateKey)
    }

    @Test
    func importsAES256CBCKey() throws {
        let privateKey = try #require(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ed25519_aes256cbc"),
                passphrase: Self.passphrase
            )
        )
        #expect(
            privateKey.publicKeyBlob
                == (try Self.publicKeyBlob(named: "ed25519_aes256cbc.pub"))
        )
        try Self.expectSignature(privateKey)
    }

    @Test
    func rejectsWrongPassphrase() throws {
        #expect(throws: OpenSSHPrivateKeyError.invalidPassphrase) {
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ed25519_aes256ctr"),
                passphrase: "not-the-passphrase"
            )
        }
    }

    @Test
    func requiresPassphraseForEncryptedKey() throws {
        #expect(throws: OpenSSHPrivateKeyError.passphraseRequired) {
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ed25519_aes256ctr"),
                passphrase: nil
            )
        }
    }

    @Test
    func ignoresNonOpenSSHKeyFormats() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-\(UUID().uuidString)-key.pem")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        -----BEGIN RSA PRIVATE KEY-----
        AAAA
        -----END RSA PRIVATE KEY-----
        """.write(to: url, atomically: true, encoding: .utf8)

        #expect(try OpenSSHPrivateKeyLoader.loadEd25519(url: url, passphrase: nil) == nil)
    }

    @Test
    func ignoresOtherOpenSSHKeyAlgorithms() throws {
        #expect(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ecdsa_openssh_unsupported"),
                passphrase: nil
            ) == nil
        )
    }

    @Test
    func ignoresEncryptedNonEd25519Key() throws {
        #expect(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ecdsa_openssh_encrypted"),
                passphrase: Self.passphrase
            ) == nil
        )
        #expect(
            try OpenSSHPrivateKeyLoader.loadEd25519(
                url: Self.fixture("ecdsa_openssh_encrypted"),
                passphrase: nil
            ) == nil
        )
    }

    @Test
    func rejectsMalformedOpenSSHKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-\(UUID().uuidString)-key")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        -----BEGIN OPENSSH PRIVATE KEY-----
        AAAA
        -----END OPENSSH PRIVATE KEY-----
        """.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: OpenSSHPrivateKeyError.malformed) {
            try OpenSSHPrivateKeyLoader.loadEd25519(url: url, passphrase: nil)
        }
    }
}
