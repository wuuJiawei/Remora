import Foundation
import Network

public enum PortForwardState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopped
    case failed(String)
}

public struct ActivePortForward: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let host: Host
    public let preset: HostPortForwardPreset
    public var state: PortForwardState

    public init(
        id: UUID = UUID(),
        host: Host,
        preset: HostPortForwardPreset,
        state: PortForwardState
    ) {
        self.id = id
        self.host = host
        self.preset = preset
        self.state = state
    }
}

public enum PortForwardValidation {
    public static func validate(_ preset: HostPortForwardPreset) -> String? {
        guard preset.kind == .local else {
            return "Unsupported port forward kind"
        }
        guard !normalizedHost(preset.localAddress).isEmpty else {
            return "Local bind address cannot be empty"
        }
        guard !normalizedHost(preset.remoteAddress).isEmpty else {
            return "Remote destination cannot be empty"
        }
        guard isValidPort(preset.localPort) else {
            return "Local port must be between 1 and 65535"
        }
        guard isValidPort(preset.remotePort) else {
            return "Remote port must be between 1 and 65535"
        }
        return nil
    }

    public static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    static func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public actor NativeLocalPortForward {
    public nonisolated let id = UUID()

    public typealias StateHandler = @Sendable (PortForwardState) -> Void
    public typealias DiagnosticHandler = @Sendable (String) -> Void

    private static let bufferSize = 32 * 1_024
    private static let listenerQueue = DispatchQueue(
        label: "io.lighting-tech.remora.native-port-forward",
        qos: .userInitiated
    )

    private let lease: any RemoteSessionLeaseProtocol
    private let preset: HostPortForwardPreset
    private let stateHandler: StateHandler?
    private let diagnosticHandler: DiagnosticHandler?

    private var listener: NWListener?
    private var clients: [UUID: NativeLocalForwardConnection] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopped = false
    private var leaseReleased = false

    public init(
        lease: any RemoteSessionLeaseProtocol,
        preset: HostPortForwardPreset,
        stateHandler: StateHandler? = nil,
        diagnosticHandler: DiagnosticHandler? = nil
    ) {
        self.lease = lease
        self.preset = preset
        self.stateHandler = stateHandler
        self.diagnosticHandler = diagnosticHandler
    }

    public func start() async throws {
        if let validationError = PortForwardValidation.validate(preset) {
            stateHandler?(.failed(validationError))
            await stop(reportStopped: false)
            throw forwardError(code: "configuration_invalid", message: validationError)
        }
        guard listener == nil, !stopped else {
            throw forwardError(
                code: "forward_already_started",
                message: "Local port forward has already been started"
            )
        }

        stateHandler?(.starting)
        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            let localAddress = PortForwardValidation.normalizedHost(preset.localAddress)
            if !Self.isWildcardAddress(localAddress) {
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(localAddress),
                    port: try Self.port(preset.localPort)
                )
            }
            listener = try NWListener(using: parameters, on: try Self.port(preset.localPort))
        } catch {
            let message = "Unable to bind local port \(preset.localPort): \(error.localizedDescription)"
            stateHandler?(.failed(message))
            await stop(reportStopped: false)
            throw forwardError(code: "listener_creation_failed", message: message)
        }

        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    startContinuation = continuation
                    listener.start(queue: Self.listenerQueue)
                }
            } onCancel: {
                listener.cancel()
            }
        } catch {
            await stop(reportStopped: false)
            throw error
        }
    }

    public func stop() async {
        await stop(reportStopped: true)
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped else {
            connection.cancel()
            return
        }

        do {
            let session = try await lease.session()
            let source = Self.sourceEndpoint(for: connection.endpoint)
            let channel = try await session.openDirectTCPIP(
                destinationHost: PortForwardValidation.normalizedHost(preset.remoteAddress),
                destinationPort: preset.remotePort,
                sourceHost: source.host,
                sourcePort: source.port
            )
            guard !stopped else {
                await channel.close()
                connection.cancel()
                return
            }

            let client = NativeLocalForwardConnection(
                connection: connection,
                channel: channel,
                bufferSize: Self.bufferSize
            )
            clients[client.id] = client
            diagnosticHandler?("forward=\(id.uuidString) client=\(client.id.uuidString) opened")
            Task { [weak self] in
                let failure = await client.run()
                await self?.clientFinished(id: client.id, failure: failure)
            }
        } catch {
            connection.cancel()
            diagnosticHandler?(
                "forward=\(id.uuidString) clientOpenFailed=\(Self.safeErrorDescription(error))"
            )
        }
    }

    private func clientFinished(id clientID: UUID, failure: Error?) {
        clients.removeValue(forKey: clientID)
        let detail = failure.map(Self.safeErrorDescription) ?? "none"
        diagnosticHandler?("forward=\(id.uuidString) client=\(clientID.uuidString) closed failure=\(detail)")
    }

    private func handleListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            startContinuation?.resume()
            startContinuation = nil
            stateHandler?(.running)
            diagnosticHandler?(
                "forward=\(id.uuidString) listenerReady localPort=\(preset.localPort) remotePort=\(preset.remotePort)"
            )
        case .failed(let error):
            let message = "Local port forward listener failed: \(error.localizedDescription)"
            startContinuation?.resume(throwing: forwardError(code: "listener_failed", message: message))
            startContinuation = nil
            stateHandler?(.failed(message))
            await stop(reportStopped: false)
        case .cancelled:
            if let startContinuation {
                self.startContinuation = nil
                startContinuation.resume(throwing: CancellationError())
            }
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func stop(reportStopped: Bool) async {
        guard !stopped else { return }
        stopped = true

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: CancellationError())
        }

        let activeClients = Array(clients.values)
        clients.removeAll(keepingCapacity: false)
        for client in activeClients {
            await client.stop()
        }
        if !leaseReleased {
            leaseReleased = true
            await lease.release()
        }
        if reportStopped {
            stateHandler?(.stopped)
        }
        diagnosticHandler?("forward=\(id.uuidString) stopped clientCount=\(activeClients.count)")
    }

    private static func port(_ value: Int) throws -> NWEndpoint.Port {
        guard let port = NWEndpoint.Port(rawValue: UInt16(value)) else {
            throw forwardError(code: "port_invalid", message: "Port is outside the valid range")
        }
        return port
    }

    private static func isWildcardAddress(_ address: String) -> Bool {
        address == "*" || address == "0.0.0.0" || address == "::"
    }

    private static func sourceEndpoint(for endpoint: NWEndpoint) -> (host: String, port: Int) {
        guard case .hostPort(let host, let port) = endpoint else {
            return ("127.0.0.1", 0)
        }
        return (String(describing: host), Int(port.rawValue))
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        if let operationError = error as? RemoteOperationError {
            return "category=\(operationError.category.rawValue) code=\(operationError.code)"
        }
        if error is CancellationError { return "cancelled" }
        return String(error.localizedDescription.prefix(256))
    }

    private static func forwardError(code: String, message: String) -> RemoteOperationError {
        RemoteOperationError(
            category: .network,
            code: code,
            safeDiagnosticMessage: message
        )
    }

    private func forwardError(code: String, message: String) -> RemoteOperationError {
        Self.forwardError(code: code, message: message)
    }
}

private actor NativeLocalForwardConnection {
    nonisolated let id = UUID()

    private let connection: NWConnection
    private let channel: any RemoteForwardChannelProtocol
    private let bufferSize: Int
    private var stopped = false

    init(
        connection: NWConnection,
        channel: any RemoteForwardChannelProtocol,
        bufferSize: Int
    ) {
        self.connection = connection
        self.channel = channel
        self.bufferSize = bufferSize
    }

    func run() async -> Error? {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.pumpLocalToRemote(
                        connection: self.connection,
                        channel: self.channel,
                        bufferSize: self.bufferSize
                    )
                }
                group.addTask {
                    try await Self.pumpRemoteToLocal(
                        connection: self.connection,
                        channel: self.channel,
                        bufferSize: self.bufferSize
                    )
                }
                try await group.waitForAll()
            }
            await stop()
            return nil
        } catch {
            await stop()
            return error
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        connection.cancel()
        await channel.close()
    }

    private static func pumpLocalToRemote(
        connection: NWConnection,
        channel: any RemoteForwardChannelProtocol,
        bufferSize: Int
    ) async throws {
        while true {
            let chunk = try await receive(from: connection, maximumBytes: bufferSize)
            if let data = chunk.data, !data.isEmpty {
                try await channel.write(data)
            }
            if chunk.isComplete {
                try await channel.finishWriting()
                return
            }
        }
    }

    private static func pumpRemoteToLocal(
        connection: NWConnection,
        channel: any RemoteForwardChannelProtocol,
        bufferSize: Int
    ) async throws {
        while let data = try await channel.read(maximumBytes: bufferSize) {
            guard !data.isEmpty else { continue }
            try await send(data, over: connection, isComplete: false)
        }
        try await send(nil, over: connection, isComplete: true)
    }

    private static func receive(
        from connection: NWConnection,
        maximumBytes: Int
    ) async throws -> (data: Data?, isComplete: Bool) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: maximumBytes
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (data, isComplete))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func send(
        _ data: Data?,
        over connection: NWConnection,
        isComplete: Bool
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: data,
                    contentContext: isComplete ? .finalMessage : .defaultMessage,
                    isComplete: isComplete,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
