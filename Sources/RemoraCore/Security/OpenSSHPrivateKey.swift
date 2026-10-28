import CryptoKit
import Foundation
import RemoraSSHNative

/// Errors raised while importing an OpenSSH-format private key.
enum OpenSSHPrivateKeyError: Error, Equatable {
    case unreadable
    case malformed
    case passphraseRequired
    case invalidPassphrase
    case unsupportedCipher(String)
    case unsupportedKeyDerivation(String)
}

/// An imported `ssh-ed25519` private key that can sign SSH user
/// authentication payloads.
///
/// The bundled libssh2 build uses the mbedTLS crypto backend, which has no
/// Ed25519 support and cannot parse OpenSSH-format private keys. Keys of that
/// shape are imported here and signed with CryptoKit instead.
public struct OpenSSHEd25519PrivateKey: Sendable {
    private let signingKey: Curve25519.Signing.PrivateKey

    /// The public key in SSH wire format (`ssh-ed25519` key blob).
    public let publicKeyBlob: Data

    init(signingKey: Curve25519.Signing.PrivateKey) {
        self.signingKey = signingKey
        self.publicKeyBlob = Self.publicKeyBlob(for: signingKey.publicKey.rawRepresentation)
    }

    func signature(for data: Data) -> Data? {
        try? signingKey.signature(for: data)
    }

    private static func publicKeyBlob(for publicKey: Data) -> Data {
        var blob = Data()
        blob.append(SSHKeyWire.string(Data("ssh-ed25519".utf8)))
        blob.append(SSHKeyWire.string(publicKey))
        return blob
    }
}

/// Reads unencrypted and bcrypt-encrypted `openssh-key-v1` private keys and
/// extracts their embedded Ed25519 signing key.
enum OpenSSHPrivateKeyLoader {
    private static let maximumKeyBytes = 16 * 1_024 * 1_024
    private static let maximumNameBytes = 64
    private static let maximumSaltBytes = 256
    private static let maximumBCryptRounds: UInt32 = 1_000_000
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Data("openssh-key-v1\0".utf8)
    private static let ed25519Algorithm = "ssh-ed25519"

    private struct CipherSpec {
        let keyLength: Int
        let ivLength: Int
        let usesCBC: Bool
    }

    private static let ciphers: [String: CipherSpec] = [
        "aes128-ctr": CipherSpec(keyLength: 16, ivLength: 16, usesCBC: false),
        "aes192-ctr": CipherSpec(keyLength: 24, ivLength: 16, usesCBC: false),
        "aes256-ctr": CipherSpec(keyLength: 32, ivLength: 16, usesCBC: false),
        "aes128-cbc": CipherSpec(keyLength: 16, ivLength: 16, usesCBC: true),
        "aes192-cbc": CipherSpec(keyLength: 24, ivLength: 16, usesCBC: true),
        "aes256-cbc": CipherSpec(keyLength: 32, ivLength: 16, usesCBC: true),
    ]

    private struct Header {
        let algorithm: String
        let cipherName: String
        let kdfName: String
        let kdfOptions: [UInt8]
        let publicKeyBlob: [UInt8]
        let privateSection: [UInt8]
    }

    private struct KDFParameters {
        let salt: [UInt8]
        let rounds: UInt32
    }

    /// Returns the imported key, or `nil` when the file is not an
    /// OpenSSH-format Ed25519 private key (the caller keeps using the
    /// libssh2 file-based authentication path in that case).
    static func loadEd25519(url: URL, passphrase: String?) throws -> OpenSSHEd25519PrivateKey? {
        guard var decoded = try decodeOpenSSHKey(at: url) else {
            return nil
        }
        defer { zeroSensitiveBytes(&decoded) }

        let header = try parseHeader(decoded)
        guard header.algorithm == ed25519Algorithm else {
            return nil
        }
        guard let embeddedPublicKey = SSHKeyWire.ed25519PublicKey(in: header.publicKeyBlob) else {
            throw OpenSSHPrivateKeyError.malformed
        }

        var privateSection = header.privateSection
        defer { zeroSensitiveBytes(&privateSection) }
        if header.cipherName != "none" {
            privateSection = try decrypt(
                privateSection,
                cipherName: header.cipherName,
                kdfName: header.kdfName,
                kdfOptions: header.kdfOptions,
                passphrase: passphrase
            )
        }

        let (signingKey, sectionPublicKey) = try parseEd25519PrivateSection(
            privateSection,
            encrypted: header.cipherName != "none"
        )
        guard sectionPublicKey == embeddedPublicKey,
              signingKey.publicKey.rawRepresentation == embeddedPublicKey
        else {
            throw OpenSSHPrivateKeyError.malformed
        }

        return OpenSSHEd25519PrivateKey(signingKey: signingKey)
    }

    private static func decodeOpenSSHKey(at url: URL) throws -> [UInt8]? {
        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            throw OpenSSHPrivateKeyError.unreadable
        }
        guard resourceValues.isRegularFile == true,
              let fileSize = resourceValues.fileSize,
              fileSize > 0,
              fileSize <= maximumKeyBytes
        else {
            throw OpenSSHPrivateKeyError.unreadable
        }

        var data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OpenSSHPrivateKeyError.unreadable
        }
        defer { zeroSensitiveData(&data) }

        guard let beginRange = data.range(of: Data(beginMarker.utf8)) else {
            return nil
        }
        guard let endRange = data.range(
            of: Data(endMarker.utf8),
            in: beginRange.upperBound..<data.endIndex
        ) else {
            throw OpenSSHPrivateKeyError.malformed
        }

        var base64Body = data[beginRange.upperBound..<endRange.lowerBound]
            .filter { !isBase64Whitespace($0) }
        defer { zeroSensitiveData(&base64Body) }

        guard let decodedValue = Data(base64Encoded: Data(base64Body)) else {
            throw OpenSSHPrivateKeyError.malformed
        }
        var decodedData = decodedValue
        defer { zeroSensitiveData(&decodedData) }
        return [UInt8](decodedData)
    }

    private static func parseHeader(_ decoded: [UInt8]) throws -> Header {
        try decoded.withUnsafeBytes { rawBuffer -> Header in
            var reader = SSHKeyBinaryReader(bytes: rawBuffer)
            guard try reader.readBytes(count: magic.count) == [UInt8](magic) else {
                throw OpenSSHPrivateKeyError.malformed
            }

            let cipherName = try reader.readUTF8String(limit: maximumNameBytes)
            let kdfName = try reader.readUTF8String(limit: maximumNameBytes)
            let kdfOptions = try reader.readSSHString()
            guard try reader.readUInt32() == 1 else {
                throw OpenSSHPrivateKeyError.malformed
            }

            let publicKeyBlob = try reader.readSSHString()
            let privateSection = try reader.readSSHString()
            guard let algorithm = SSHKeyWire.algorithm(in: publicKeyBlob) else {
                throw OpenSSHPrivateKeyError.malformed
            }

            return Header(
                algorithm: algorithm,
                cipherName: cipherName,
                kdfName: kdfName,
                kdfOptions: kdfOptions,
                publicKeyBlob: publicKeyBlob,
                privateSection: privateSection
            )
        }
    }

    private static func parseEd25519PrivateSection(
        _ privateSection: [UInt8],
        encrypted: Bool
    ) throws -> (signingKey: Curve25519.Signing.PrivateKey, publicKey: Data) {
        try privateSection.withUnsafeBytes { rawBuffer -> (Curve25519.Signing.PrivateKey, Data) in
            var reader = SSHKeyBinaryReader(bytes: rawBuffer)
            let check1 = try reader.readUInt32()
            let check2 = try reader.readUInt32()
            guard check1 == check2 else {
                throw encrypted
                    ? OpenSSHPrivateKeyError.invalidPassphrase
                    : OpenSSHPrivateKeyError.malformed
            }
            guard try reader.readUTF8String(limit: maximumNameBytes) == ed25519Algorithm else {
                throw OpenSSHPrivateKeyError.malformed
            }

            let publicKey = try reader.readSSHString()
            var secret = try reader.readSSHString()
            defer { zeroSensitiveBytes(&secret) }
            guard publicKey.count == 32,
                  secret.count == 64,
                  Array(secret[32...]) == publicKey
            else {
                throw OpenSSHPrivateKeyError.malformed
            }

            guard let signingKey = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: Data(secret.prefix(32))
            ) else {
                throw OpenSSHPrivateKeyError.malformed
            }
            return (signingKey, Data(publicKey))
        }
    }

    private static func decrypt(
        _ privateSection: [UInt8],
        cipherName: String,
        kdfName: String,
        kdfOptions: [UInt8],
        passphrase: String?
    ) throws -> [UInt8] {
        guard let passphrase, !passphrase.isEmpty else {
            throw OpenSSHPrivateKeyError.passphraseRequired
        }
        guard let cipher = ciphers[cipherName] else {
            throw OpenSSHPrivateKeyError.unsupportedCipher(cipherName)
        }
        guard kdfName == "bcrypt" else {
            throw OpenSSHPrivateKeyError.unsupportedKeyDerivation(kdfName)
        }

        let kdfParameters = try parseKDFParameters(kdfOptions)
        var material = [UInt8](repeating: 0, count: cipher.keyLength + cipher.ivLength)
        defer { zeroSensitiveBytes(&material) }
        let derivationStatus = deriveKeyMaterial(
            passphrase: passphrase,
            salt: kdfParameters.salt,
            rounds: kdfParameters.rounds,
            into: &material
        )
        guard derivationStatus == 0 else {
            throw OpenSSHPrivateKeyError.malformed
        }

        var output = [UInt8](repeating: 0, count: privateSection.count)
        let decryptionStatus = material.withUnsafeBufferPointer { materialBuffer -> Int32 in
            privateSection.withUnsafeBufferPointer { inputBuffer -> Int32 in
                output.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                    remora_ssh_openssh_private_key_decrypt(
                        materialBuffer.baseAddress,
                        size_t(cipher.keyLength),
                        materialBuffer.baseAddress.map { $0.advanced(by: cipher.keyLength) },
                        size_t(cipher.ivLength),
                        inputBuffer.baseAddress,
                        size_t(inputBuffer.count),
                        outputBuffer.baseAddress,
                        cipher.usesCBC
                    )
                }
            }
        }
        guard decryptionStatus == 0 else {
            throw OpenSSHPrivateKeyError.malformed
        }
        return output
    }

    private static func parseKDFParameters(_ kdfOptions: [UInt8]) throws -> KDFParameters {
        try kdfOptions.withUnsafeBytes { rawBuffer -> KDFParameters in
            var reader = SSHKeyBinaryReader(bytes: rawBuffer)
            let salt = try reader.readSSHString()
            let rounds = try reader.readUInt32()
            guard salt.count <= maximumSaltBytes,
                  rounds > 0,
                  rounds <= maximumBCryptRounds
            else {
                throw OpenSSHPrivateKeyError.malformed
            }
            return KDFParameters(salt: salt, rounds: rounds)
        }
    }

    private static func deriveKeyMaterial(
        passphrase: String,
        salt: [UInt8],
        rounds: UInt32,
        into output: inout [UInt8]
    ) -> Int32 {
        var passphraseBytes = Array(passphrase.utf8)
        defer { zeroSensitiveBytes(&passphraseBytes) }

        let status = passphraseBytes.withUnsafeBufferPointer { passphraseBuffer -> Int32 in
            salt.withUnsafeBufferPointer { saltBuffer -> Int32 in
                output.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                    guard let passphraseBase = passphraseBuffer.baseAddress,
                          let saltBase = saltBuffer.baseAddress,
                          let outputBase = outputBuffer.baseAddress
                    else {
                        return -1
                    }
                    return remora_ssh_bcrypt_pbkdf(
                        UnsafeRawPointer(passphraseBase).assumingMemoryBound(to: CChar.self),
                        size_t(passphraseBuffer.count),
                        saltBase,
                        size_t(saltBuffer.count),
                        outputBase,
                        size_t(outputBuffer.count),
                        rounds
                    )
                }
            }
        }
        return status
    }
}

/// Helpers for reading and writing SSH key wire encoding
/// (`uint32` length-prefixed strings).
enum SSHKeyWire {
    static func string(_ payload: Data) -> Data {
        var encoded = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
        encoded.append(payload)
        return encoded
    }

    static func algorithm(in blob: [UInt8]) -> String? {
        blob.withUnsafeBytes { rawBuffer -> String? in
            var reader = SSHKeyBinaryReader(bytes: rawBuffer)
            return try? reader.readUTF8String(limit: 64)
        }
    }

    static func ed25519PublicKey(in blob: [UInt8]) -> Data? {
        blob.withUnsafeBytes { rawBuffer -> Data? in
            var reader = SSHKeyBinaryReader(bytes: rawBuffer)
            guard let algorithm = try? reader.readUTF8String(limit: 64),
                  algorithm == "ssh-ed25519",
                  let publicKey = try? reader.readSSHString(),
                  publicKey.count == 32
            else {
                return nil
            }
            return Data(publicKey)
        }
    }
}

/// Bounds-checked reader for SSH binary key data. It borrows a raw buffer so
/// sensitive arrays are not retained through copy-on-write aliases and can be
/// zeroed deterministically after parsing.
private struct SSHKeyBinaryReader {
    private let bytes: UnsafeRawBufferPointer
    private var offset = 0

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw OpenSSHPrivateKeyError.malformed
        }
        defer { offset += 4 }
        var value: UInt32 = 0
        for byte in bytes[offset..<offset + 4] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else {
            throw OpenSSHPrivateKeyError.malformed
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readSSHString() throws -> [UInt8] {
        let length = Int(try readUInt32())
        return try readBytes(count: length)
    }

    mutating func readUTF8String(limit: Int) throws -> String {
        let value = try readSSHString()
        guard value.count <= limit,
              let string = String(bytes: value, encoding: .utf8)
        else {
            throw OpenSSHPrivateKeyError.malformed
        }
        return string
    }
}

private func isBase64Whitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
}

/// Best-effort zeroing for transient private key material. The arrays passed
/// here must be uniquely referenced, otherwise copy-on-write would zero a copy.
private func zeroSensitiveBytes(_ bytes: inout [UInt8]) {
    guard !bytes.isEmpty else { return }
    bytes.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        memset(baseAddress, 0, buffer.count)
    }
}

private func zeroSensitiveData(_ data: inout Data) {
    guard !data.isEmpty else { return }
    data.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        memset(baseAddress, 0, buffer.count)
    }
}
