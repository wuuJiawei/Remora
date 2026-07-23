import Foundation

public actor LibSSH2Transport {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case ready
        case failed(RemoteSessionFailure)
        case closing
        case closed
    }

    public let id: UUID

    private let hostKeyVerifier: HostKeyVerifier
    private let executor: NativeSSHSerialExecutor
    private let diagnosticLog: NativeSSHDiagnosticLog
    private let connector = NativeTCPConnector()

    private var state: State = .idle
    private var activeConnectionID: UUID?
    private var runtime: NativeSSHRuntime?
    private var authenticationCoordinator: AuthenticationCoordinator?

    public init(
        id: UUID = UUID(),
        hostKeyVerifier: HostKeyVerifier
    ) {
        self.id = id
        self.hostKeyVerifier = hostKeyVerifier
        executor = NativeSSHSerialExecutor(label: "io.lighting-tech.remora.native-ssh.transport.\(id.uuidString)")
        diagnosticLog = NativeSSHDiagnosticLog(connectionID: id)
    }

    deinit {
        authenticationCoordinator?.cancel()
        runtime?.scheduleClose()
    }

    public func currentState() -> State {
        state
    }

    public func diagnostics() -> AsyncStream<NativeSSHDiagnosticEvent> {
        diagnosticLog.stream
    }

    public func connect(configuration: NativeSSHConnectionConfiguration) async throws {
        guard state == .idle else {
            throw RemoteOperationError(
                category: .session,
                code: "transport_invalid_state",
                safeDiagnosticMessage: "Native SSH transport cannot connect from its current state"
            )
        }

        let connectionID = UUID()
        activeConnectionID = connectionID
        state = .connecting
        authenticationCoordinator = configuration.authentication.coordinator
        emit(.resolving, operation: "connect", message: endpointDiagnostic(configuration.endpoint))

        var pendingRuntime: NativeSSHRuntime?
        do {
            let socket = try await connector.connect(
                to: configuration.endpoint,
                timeout: configuration.connectTimeout
            ) { [diagnosticLog] message in
                diagnosticLog.emit(
                    phase: .connecting,
                    operation: "tcp_connect",
                    message: message
                )
            }
            try ensureActive(connectionID)

            let context = try await executor.perform {
                try NativeSSHContext()
            }
            let runtime = NativeSSHRuntime(
                executor: executor,
                context: context,
                socket: socket,
                operationTimeout: configuration.operationTimeout,
                diagnosticLog: diagnosticLog
            )
            pendingRuntime = runtime
            self.runtime = runtime

            emit(
                .handshaking,
                operation: "handshake",
                message: "backend=\(NativeSSHContext.backendVersion) crypto=\(NativeSSHContext.cryptoBackend)"
            )
            try await runtime.run(
                phase: .handshaking,
                operation: "handshake",
                timeout: configuration.operationTimeout
            ) {
                try context.handshake(socketDescriptor: socket.descriptor())
            }
            try ensureActive(connectionID)

            emit(.verifyingHostKey, operation: "host_key", message: "reading server host key")
            let hostKey = try await runtime.perform {
                try context.hostKey()
            }
            try await hostKeyVerifier.verify(endpoint: configuration.endpoint, hostKey: hostKey)
            emit(
                .verifyingHostKey,
                operation: "host_key",
                message: "trusted algorithm=\(hostKey.algorithm.rawValue) fingerprint=\(hostKey.fingerprint)"
            )
            try ensureActive(connectionID)

            emit(
                .authenticating,
                operation: "authentication_methods",
                message: "requesting advertised methods"
            )
            let advertisedMethods = try await runtime.runResult(
                phase: .authenticating,
                operation: "authentication_methods",
                timeout: configuration.operationTimeout
            ) {
                let result = try context.authenticationMethods(username: configuration.username)
                return (result.0, result.1)
            }
            try validate(
                authentication: configuration.authentication,
                advertisedMethods: advertisedMethods
            )

            emit(
                .authenticating,
                operation: configuration.authentication.diagnosticName,
                message: "authentication started advertised=\(advertisedMethods.map(\.rawValue).sorted().joined(separator: ","))"
            )
            try await authenticate(
                configuration.authentication,
                advertisedMethods: advertisedMethods,
                username: configuration.username,
                runtime: runtime,
                context: context,
                timeout: configuration.operationTimeout
            )
            try ensureActive(connectionID)

            let authenticated = try await runtime.perform {
                context.isAuthenticated
            }
            guard authenticated else {
                throw RemoteOperationError(
                    category: .authentication,
                    code: "authentication_incomplete",
                    safeDiagnosticMessage: "SSH backend did not enter the authenticated state"
                )
            }

            state = .ready
            emit(.ready, operation: "connect", message: "native SSH transport ready")
        } catch {
            authenticationCoordinator?.cancel()
            authenticationCoordinator = nil
            pendingRuntime?.beginClosing()
            await pendingRuntime?.close()
            if activeConnectionID == connectionID {
                runtime = nil
                activeConnectionID = nil
                let operationError = Self.operationError(from: error)
                state = .failed(RemoteSessionFailure(operationError))
                emit(
                    .failed,
                    operation: "connect",
                    backendCode: operationError.backendCode,
                    message: "code=\(operationError.code) detail=\(operationError.safeDiagnosticMessage)"
                )
            }
            throw error
        }
    }

    public func openShell(
        pty: PTYSize,
        terminalType: String = "xterm-256color"
    ) async throws -> NativeShellChannel {
        guard state == .ready, let runtime else {
            throw RemoteOperationError(
                category: .session,
                code: "transport_not_ready",
                safeDiagnosticMessage: "Native SSH transport is not ready"
            )
        }
        guard pty.columns > 0, pty.rows > 0, !terminalType.isEmpty else {
            throw RemoteOperationError(
                category: .channel,
                code: "invalid_pty",
                safeDiagnosticMessage: "SSH PTY dimensions or terminal type are invalid"
            )
        }

        emit(
            .openingShell,
            operation: "shell_allocate",
            message: "columns=\(pty.columns) rows=\(pty.rows) terminal=\(terminalType)"
        )
        let handle = try await runtime.perform {
            try runtime.context.createShell(pty: pty, terminalType: terminalType)
        }
        return NativeShellChannel(
            handle: handle,
            runtime: runtime,
            diagnosticLog: diagnosticLog
        )
    }

    public func openDirectTCPIP(
        destinationHost: String,
        destinationPort: Int,
        sourceHost: String,
        sourcePort: Int
    ) async throws -> NativeDirectTCPIPChannel {
        guard state == .ready, let runtime else {
            throw RemoteOperationError(
                category: .session,
                code: "transport_not_ready",
                safeDiagnosticMessage: "Native SSH transport is not ready"
            )
        }
        guard !destinationHost.isEmpty,
              (1...65_535).contains(destinationPort),
              !sourceHost.isEmpty,
              (0...65_535).contains(sourcePort)
        else {
            throw RemoteOperationError(
                category: .channel,
                code: "direct_tcpip_endpoint_invalid",
                safeDiagnosticMessage: "Direct TCP/IP channel endpoint is invalid"
            )
        }

        let handle = try await runtime.perform {
            try runtime.context.createDirectTCPIP(
                destinationHost: destinationHost,
                destinationPort: UInt16(destinationPort),
                sourceHost: sourceHost,
                sourcePort: UInt16(sourcePort)
            )
        }
        do {
            try await runtime.run(phase: .ready, operation: "direct_tcpip_start") {
                try handle.start()
            }
            return NativeDirectTCPIPChannel(
                handle: handle,
                runtime: runtime,
                diagnosticLog: diagnosticLog
            )
        } catch {
            await runtime.destroyChannel(handle)
            throw error
        }
    }

    func recordDiagnostic(operation: String, message: String, backendCode: Int? = nil) {
        emit(.ready, operation: operation, backendCode: backendCode, message: message)
    }

    func openCommand(_ command: String, timeout: Duration?) async throws -> NativeCommandExecution {
        guard state == .ready, let runtime else {
            throw RemoteOperationError(
                category: .session,
                code: "transport_not_ready",
                safeDiagnosticMessage: "Native SSH transport is not ready"
            )
        }
        guard !command.isEmpty else {
            throw RemoteOperationError(
                category: .command,
                code: "command_empty",
                safeDiagnosticMessage: "Remote command is empty"
            )
        }
        let handle = try await runtime.perform {
            try runtime.context.createExec(command: command)
        }
        return NativeCommandExecution(
            handle: handle,
            runtime: runtime,
            diagnosticLog: diagnosticLog,
            timeout: timeout
        )
    }

    func openFileSystem(
        onClose: @escaping @Sendable (UUID) async -> Void
    ) async throws -> LibSSH2RemoteFileSystem {
        guard state == .ready, let runtime else {
            throw RemoteOperationError(
                category: .session,
                code: "transport_not_ready",
                safeDiagnosticMessage: "Native SSH transport is not ready"
            )
        }
        emit(.ready, operation: "sftp_allocate", message: "allocating native SFTP subsystem")
        let handle = try await runtime.perform {
            try runtime.context.createSFTP()
        }
        do {
            try await runtime.run(phase: .ready, operation: "sftp_start") {
                try handle.start()
            }
            return LibSSH2RemoteFileSystem(
                runtime: runtime,
                sessionHandle: handle,
                onClose: onClose
            )
        } catch {
            _ = try? await runtime.run(
                phase: .closing,
                operation: "sftp_start_cleanup",
                allowClosing: true
            ) {
                try handle.close()
            }
            throw error
        }
    }

    public func close() async {
        guard state != .closing, state != .closed else { return }
        state = .closing
        activeConnectionID = nil
        emit(.closing, operation: "transport_close", message: "closing native SSH transport")

        authenticationCoordinator?.cancel()
        authenticationCoordinator = nil
        let runtime = self.runtime
        self.runtime = nil
        runtime?.beginClosing()
        await runtime?.close()

        state = .closed
        emit(.closed, operation: "transport_close", message: "native SSH transport closed")
        diagnosticLog.finish()
    }

    private func authenticate(
        _ authentication: NativeSSHAuthentication,
        advertisedMethods: Set<NativeSSHAuthenticationMethod>,
        username: String,
        runtime: NativeSSHRuntime,
        context: NativeSSHContext,
        timeout: Duration
    ) async throws {
        switch authentication {
        case .password(let password):
            try await runtime.run(phase: .authenticating, operation: "password_auth", timeout: timeout) {
                try context.authenticatePassword(username: username, password: password)
            }
        case .privateKey(let privateKey):
            try await runtime.run(phase: .authenticating, operation: "private_key_auth", timeout: timeout) {
                try context.authenticatePrivateKey(username: username, privateKey: privateKey)
            }
        case .agent:
            try await runtime.run(phase: .authenticating, operation: "agent_auth", timeout: timeout) {
                try context.authenticateAgent(username: username)
            }
        case .keyboardInteractive(let coordinator):
            try await runtime.run(
                phase: .authenticating,
                operation: "keyboard_interactive_auth",
                timeout: timeout
            ) {
                try context.authenticateKeyboardInteractive(username: username, bridge: coordinator.bridge)
            }
        case .passwordOrKeyboardInteractive(let password, let coordinator):
            if advertisedMethods.contains(.keyboardInteractive) {
                try await runtime.run(
                    phase: .authenticating,
                    operation: "keyboard_interactive_auth",
                    timeout: timeout
                ) {
                    try context.authenticateKeyboardInteractive(username: username, bridge: coordinator.bridge)
                }
            } else {
                do {
                    try await runtime.run(phase: .authenticating, operation: "password_auth", timeout: timeout) {
                        try context.authenticatePassword(username: username, password: password)
                    }
                } catch {
                    guard Self.isPasswordAuthenticationFailure(error) else { throw error }
                    let remainingMethods = try await runtime.runResult(
                        phase: .authenticating,
                        operation: "authentication_methods_after_password",
                        timeout: timeout
                    ) {
                        let result = try context.authenticationMethods(username: username)
                        return (result.0, result.1)
                    }
                    guard remainingMethods.contains(.keyboardInteractive) else { throw error }
                    emit(
                        .authenticating,
                        operation: "keyboard_interactive_auth",
                        message: "continuing staged authentication after password"
                    )
                    try await runtime.run(
                        phase: .authenticating,
                        operation: "keyboard_interactive_auth",
                        timeout: timeout
                    ) {
                        try context.authenticateKeyboardInteractive(username: username, bridge: coordinator.bridge)
                    }
                }
            }
        }
    }

    private func validate(
        authentication: NativeSSHAuthentication,
        advertisedMethods: Set<NativeSSHAuthenticationMethod>
    ) throws {
        let isAvailable: Bool
        switch authentication {
        case .passwordOrKeyboardInteractive:
            isAvailable = advertisedMethods.contains(.keyboardInteractive)
                || advertisedMethods.contains(.password)
        default:
            isAvailable = advertisedMethods.contains(authentication.advertisedMethod)
        }
        guard isAvailable else {
            throw RemoteOperationError(
                category: .authentication,
                code: "authentication_method_unavailable",
                safeDiagnosticMessage: "SSH server does not advertise the selected authentication method"
            )
        }
    }

    private static func isPasswordAuthenticationFailure(_ error: Error) -> Bool {
        guard let operationError = error as? RemoteOperationError else { return false }
        return operationError.category == .authentication
            && operationError.code == "password_authentication_failed"
    }

    private func ensureActive(_ connectionID: UUID) throws {
        guard activeConnectionID == connectionID, state == .connecting else {
            throw RemoteOperationError(
                category: .session,
                code: "connection_cancelled",
                safeDiagnosticMessage: "Native SSH connection was cancelled"
            )
        }
    }

    private func emit(
        _ phase: NativeSSHDiagnosticPhase,
        operation: String,
        backendCode: Int? = nil,
        message: String
    ) {
        diagnosticLog.emit(
            phase: phase,
            operation: operation,
            backendCode: backendCode,
            message: message
        )
    }

    private func endpointDiagnostic(_ endpoint: RemoteEndpoint) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in endpoint.hostname.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "endpointHash=\(String(hash, radix: 16)) port=\(endpoint.port)"
    }

    private static func operationError(from error: Error) -> RemoteOperationError {
        if let operationError = error as? RemoteOperationError {
            return operationError
        }
        if error is CancellationError {
            return RemoteOperationError(
                category: .session,
                code: "operation_cancelled",
                safeDiagnosticMessage: "Native SSH operation was cancelled"
            )
        }
        if case let NativeSSHContextError.creationFailed(code, backendCode, message) = error {
            return RemoteOperationError(
                category: .session,
                code: "native_context_creation_failed_\(code)",
                safeDiagnosticMessage: message,
                backendCode: Int(backendCode)
            )
        }
        return RemoteOperationError(
            category: .session,
            code: "native_transport_failed",
            safeDiagnosticMessage: "Native SSH transport failed"
        )
    }
}

final class NativeSSHSerialExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

final class NativeSSHRuntime: @unchecked Sendable {
    let context: NativeSSHContext

    private let executor: NativeSSHSerialExecutor
    private let socket: NativeSocketHandle
    private let operationTimeout: Duration
    private let diagnosticLog: NativeSSHDiagnosticLog
    private let lock = NSLock()
    private var closing = false
    private var closed = false

    init(
        executor: NativeSSHSerialExecutor,
        context: NativeSSHContext,
        socket: NativeSocketHandle,
        operationTimeout: Duration,
        diagnosticLog: NativeSSHDiagnosticLog
    ) {
        self.executor = executor
        self.context = context
        self.socket = socket
        self.operationTimeout = operationTimeout
        self.diagnosticLog = diagnosticLog
    }

    func perform<Value: Sendable>(
        allowClosing: Bool = false,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try ensureAvailable(allowClosing: allowClosing)
        return try await executor.perform(operation)
    }

    func run(
        phase: NativeSSHDiagnosticPhase,
        operation: String,
        timeout: Duration? = nil,
        allowClosing: Bool = false,
        _ call: @escaping @Sendable () throws -> NativeSSHCallStatus
    ) async throws {
        let timeout = timeout ?? operationTimeout
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var waitCount = 0

        do {
            while true {
                try Task.checkCancellation()
                try ensureAvailable(allowClosing: allowClosing)
                switch try await executor.perform(call) {
                case .complete:
                    diagnosticLog.emit(
                        phase: phase,
                        operation: operation,
                        message: "completed waitCount=\(waitCount)"
                    )
                    return
                case .wouldBlock(let directions):
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .zero else {
                        throw RemoteOperationError(
                            category: .network,
                            code: "operation_timeout",
                            safeDiagnosticMessage: "Native SSH operation timed out"
                        )
                    }
                    waitCount += 1
                    try await SocketReadiness.wait(
                        for: socket.descriptor(),
                        directions: directions,
                        timeout: remaining
                    )
                }
            }
        } catch {
            let operationError = error as? RemoteOperationError
            diagnosticLog.emit(
                phase: .failed,
                operation: operation,
                backendCode: operationError?.backendCode,
                message: "failed waitCount=\(waitCount) code=\(operationError?.code ?? "cancelled")"
            )
            throw error
        }
    }

    func runResult<Value: Sendable>(
        phase: NativeSSHDiagnosticPhase,
        operation: String,
        timeout: Duration? = nil,
        allowClosing: Bool = false,
        _ call: @escaping @Sendable () throws -> (NativeSSHCallStatus, Value)
    ) async throws -> Value {
        let timeout = timeout ?? operationTimeout
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var waitCount = 0

        do {
            while true {
                try Task.checkCancellation()
                try ensureAvailable(allowClosing: allowClosing)
                let result = try await executor.perform(call)
                switch result.0 {
                case .complete:
                    diagnosticLog.emit(
                        phase: phase,
                        operation: operation,
                        message: "completed waitCount=\(waitCount)"
                    )
                    return result.1
                case .wouldBlock(let directions):
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .zero else {
                        throw RemoteOperationError(
                            category: .network,
                            code: "operation_timeout",
                            safeDiagnosticMessage: "Native SSH operation timed out"
                        )
                    }
                    waitCount += 1
                    try await SocketReadiness.wait(
                        for: socket.descriptor(),
                        directions: directions,
                        timeout: remaining
                    )
                }
            }
        } catch {
            let operationError = error as? RemoteOperationError
            diagnosticLog.emit(
                phase: .failed,
                operation: operation,
                backendCode: operationError?.backendCode,
                message: "failed waitCount=\(waitCount) code=\(operationError?.code ?? "cancelled")"
            )
            throw error
        }
    }

    func waitForSocket(directions: NativeSocketDirections, timeout: Duration? = nil) async throws {
        try ensureAvailable(allowClosing: false)
        try await SocketReadiness.wait(
            for: socket.descriptor(),
            directions: directions,
            timeout: timeout ?? operationTimeout
        )
    }

    func beginClosing() {
        lock.lock()
        closing = true
        lock.unlock()
        socket.interrupt()
    }

    func close() async {
        guard markClosed() else { return }

        socket.interrupt()
        _ = try? await executor.perform { [context, socket] in
            context.close()
            socket.close()
        }
    }

    func scheduleClose() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closing = true
        closed = true
        lock.unlock()

        socket.interrupt()
        executor.schedule { [context, socket] in
            context.close()
            socket.close()
        }
    }

    func destroyChannel(_ handle: NativeSSHChannelHandle) async {
        _ = try? await executor.perform {
            handle.destroy()
        }
    }

    func scheduleDestroyChannel(_ handle: NativeSSHChannelHandle) {
        executor.schedule {
            handle.destroy()
        }
    }

    private func ensureAvailable(allowClosing: Bool) throws {
        lock.lock()
        let unavailable = closed || (closing && !allowClosing)
        lock.unlock()
        guard !unavailable else {
            throw RemoteOperationError(
                category: .session,
                code: "transport_closed",
                safeDiagnosticMessage: "Native SSH transport is closing or closed"
            )
        }
    }

    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        closing = true
        closed = true
        return true
    }
}

final class NativeSSHDiagnosticLog: @unchecked Sendable {
    let stream: AsyncStream<NativeSSHDiagnosticEvent>

    private let connectionID: UUID
    private let continuation: AsyncStream<NativeSSHDiagnosticEvent>.Continuation
    private let lock = NSLock()
    private var finished = false

    init(connectionID: UUID) {
        self.connectionID = connectionID
        let pair = AsyncStream<NativeSSHDiagnosticEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    deinit {
        finish()
    }

    func emit(
        phase: NativeSSHDiagnosticPhase,
        operation: String,
        backendCode: Int? = nil,
        message: String
    ) {
        lock.lock()
        let shouldEmit = !finished
        lock.unlock()
        guard shouldEmit else { return }

        continuation.yield(
            NativeSSHDiagnosticEvent(
                connectionID: connectionID,
                phase: phase,
                operation: operation,
                backendCode: backendCode,
                message: String(message.prefix(1_024))
            )
        )
    }

    func finish() {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish {
            continuation.finish()
        }
    }
}

private extension NativeSSHAuthentication {
    var advertisedMethod: NativeSSHAuthenticationMethod {
        switch self {
        case .password: .password
        case .privateKey, .agent: .publicKey
        case .keyboardInteractive: .keyboardInteractive
        case .passwordOrKeyboardInteractive: .keyboardInteractive
        }
    }

    var diagnosticName: String {
        switch self {
        case .password: "password_auth"
        case .privateKey: "private_key_auth"
        case .agent: "agent_auth"
        case .keyboardInteractive: "keyboard_interactive_auth"
        case .passwordOrKeyboardInteractive: "password_or_keyboard_interactive_auth"
        }
    }

    var coordinator: AuthenticationCoordinator? {
        if case .keyboardInteractive(let coordinator) = self {
            return coordinator
        }
        if case .passwordOrKeyboardInteractive(_, let coordinator) = self {
            return coordinator
        }
        return nil
    }
}
