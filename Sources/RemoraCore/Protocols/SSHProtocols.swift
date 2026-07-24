import Foundation

public protocol ShellSessionProtocol: AnyObject, Sendable {
    var onOutput: (@Sendable (Data) -> Void)? { get set }
    var onStateChange: (@Sendable (ShellSessionState) -> Void)? { get set }
    func start() async throws
    func write(_ data: Data) async throws
    func resize(_ size: PTYSize) async throws
    func stop() async
}

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
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SSH session is not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        }
    }
}
