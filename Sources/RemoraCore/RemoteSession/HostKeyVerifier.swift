import Foundation

public struct NativeSSHHostKeyTrustRequest: Equatable, Sendable {
    public let endpoint: RemoteEndpoint
    public let algorithm: NativeSSHHostKeyAlgorithm
    public let fingerprint: String

    public init(
        endpoint: RemoteEndpoint,
        algorithm: NativeSSHHostKeyAlgorithm,
        fingerprint: String
    ) {
        self.endpoint = endpoint
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }
}

public enum NativeSSHHostKeyTrustDecision: Sendable {
    case accept
    case reject
}

public struct HostKeyVerifier: Sendable {
    public typealias TrustHandler = @Sendable (NativeSSHHostKeyTrustRequest) async -> NativeSSHHostKeyTrustDecision

    private let store: HostKeyStore
    private let trustHandler: TrustHandler?

    public init(store: HostKeyStore, trustHandler: TrustHandler? = nil) {
        self.store = store
        self.trustHandler = trustHandler
    }

    public static func persistent(
        baseDirectoryURL: URL = RemoraConfigPaths.rootDirectoryURL(),
        trustHandler: TrustHandler? = nil
    ) throws -> HostKeyVerifier {
        HostKeyVerifier(
            store: try HostKeyStore.persistent(baseDirectoryURL: baseDirectoryURL),
            trustHandler: trustHandler
        )
    }

    public func verify(endpoint: RemoteEndpoint, hostKey: NativeSSHHostKey) async throws {
        let host = Self.storeKey(for: endpoint)
        switch await store.check(host: host, fingerprint: hostKey.fingerprint) {
        case .trusted:
            return
        case .changed(let old, let new):
            throw RemoteOperationError(
                category: .hostKey,
                code: "host_key_changed",
                safeDiagnosticMessage: "SSH host key mismatch old=\(old) new=\(new)"
            )
        case .firstSeen:
            guard let trustHandler else {
                throw RemoteOperationError(
                    category: .hostKey,
                    code: "host_key_untrusted",
                    safeDiagnosticMessage: "SSH host key is unknown and requires explicit trust"
                )
            }
            let decision = await trustHandler(
                NativeSSHHostKeyTrustRequest(
                    endpoint: endpoint,
                    algorithm: hostKey.algorithm,
                    fingerprint: hostKey.fingerprint
                )
            )
            guard decision == .accept else {
                throw RemoteOperationError(
                    category: .hostKey,
                    code: "host_key_rejected",
                    safeDiagnosticMessage: "SSH host key was rejected"
                )
            }
            do {
                try await store.trustPersisting(host: host, fingerprint: hostKey.fingerprint)
            } catch {
                throw RemoteOperationError(
                    category: .hostKey,
                    code: "host_key_persistence_failed",
                    safeDiagnosticMessage: "Trusted SSH host key could not be persisted"
                )
            }
        }
    }

    private static func storeKey(for endpoint: RemoteEndpoint) -> String {
        let hostname = endpoint.hostname.lowercased()
        return hostname.contains(":")
            ? "[\(hostname)]:\(endpoint.port)"
            : "\(hostname):\(endpoint.port)"
    }
}
