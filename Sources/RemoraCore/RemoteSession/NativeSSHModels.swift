import Foundation

public struct NativeSSHPrivateKey: Equatable, Sendable {
    public let privateKeyURL: URL
    public let publicKeyURL: URL?
    public let passphrase: String?

    public init(privateKeyURL: URL, publicKeyURL: URL? = nil, passphrase: String? = nil) {
        self.privateKeyURL = privateKeyURL
        self.publicKeyURL = publicKeyURL
        self.passphrase = passphrase
    }
}

public enum NativeSSHAuthentication: Sendable {
    case password(String)
    case privateKey(NativeSSHPrivateKey)
    case agent
    case keyboardInteractive(AuthenticationCoordinator)
    case passwordOrKeyboardInteractive(password: String, coordinator: AuthenticationCoordinator)
}

public struct NativeSSHConnectionConfiguration: Sendable {
    public let endpoint: RemoteEndpoint
    public let username: String
    public let authentication: NativeSSHAuthentication
    public let connectTimeout: Duration
    public let operationTimeout: Duration

    public init(
        endpoint: RemoteEndpoint,
        username: String,
        authentication: NativeSSHAuthentication,
        connectTimeout: Duration = .seconds(10),
        operationTimeout: Duration = .seconds(30)
    ) {
        self.endpoint = endpoint
        self.username = username
        self.authentication = authentication
        self.connectTimeout = connectTimeout
        self.operationTimeout = operationTimeout
    }
}

public enum NativeSSHAuthenticationMethod: String, CaseIterable, Sendable {
    case publicKey = "publickey"
    case password
    case keyboardInteractive = "keyboard-interactive"
}

public enum NativeSSHHostKeyAlgorithm: String, Sendable {
    case rsa
    case dss
    case ecdsa256
    case ecdsa384
    case ecdsa521
    case ed25519
    case unknown
}

public struct NativeSSHHostKey: Equatable, Sendable {
    public let algorithm: NativeSSHHostKeyAlgorithm
    public let sha256: Data

    public init(algorithm: NativeSSHHostKeyAlgorithm, sha256: Data) {
        self.algorithm = algorithm
        self.sha256 = sha256
    }

    public var fingerprint: String {
        "SHA256:" + sha256.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

public enum NativeSSHDiagnosticPhase: String, Sendable {
    case resolving
    case connecting
    case handshaking
    case verifyingHostKey
    case authenticating
    case ready
    case openingShell
    case closing
    case closed
    case failed
}

public struct NativeSSHDiagnosticEvent: Equatable, Sendable {
    public let timestamp: Date
    public let connectionID: UUID
    public let phase: NativeSSHDiagnosticPhase
    public let operation: String
    public let backendCode: Int?
    public let message: String

    public init(
        timestamp: Date = Date(),
        connectionID: UUID,
        phase: NativeSSHDiagnosticPhase,
        operation: String,
        backendCode: Int? = nil,
        message: String
    ) {
        self.timestamp = timestamp
        self.connectionID = connectionID
        self.phase = phase
        self.operation = operation
        self.backendCode = backendCode
        self.message = message
    }
}

struct NativeSocketDirections: OptionSet, Sendable {
    let rawValue: UInt32

    static let inbound = NativeSocketDirections(rawValue: 1 << 0)
    static let outbound = NativeSocketDirections(rawValue: 1 << 1)
    static let both: NativeSocketDirections = [.inbound, .outbound]
}

enum NativeSSHCallStatus: Sendable {
    case complete
    case wouldBlock(NativeSocketDirections)
}
