import Foundation

public protocol SSHTransportClientProtocol: Sendable {
    func connect(to host: Host) async throws
    func openShell(pty: PTYSize) async throws -> SSHTransportSessionProtocol
    func disconnect() async
}

public protocol SSHTransportSessionProtocol: AnyObject, Sendable {
    var onOutput: (@Sendable (Data) -> Void)? { get set }
    var onStateChange: (@Sendable (ShellSessionState) -> Void)? { get set }
    func start() async throws
    func write(_ data: Data) async throws
    func resize(_ size: PTYSize) async throws
    func stop() async
}

public typealias SSHClientProtocol = SSHTransportClientProtocol
public typealias SSHShellSessionProtocol = SSHTransportSessionProtocol

public struct PTYSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public enum ShellSessionState: Equatable, Sendable {
    case idle
    case running
    case stopped
    case failed(String)
}

public enum SSHError: Error, LocalizedError, Sendable {
    case notConnected
    case authFailed
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SSH client is not connected"
        case .authFailed:
            return "Authentication failed"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        }
    }
}
