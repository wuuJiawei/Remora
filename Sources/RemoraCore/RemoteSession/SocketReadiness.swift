import Darwin
import Foundation

enum SocketReadiness {
    static func wait(
        for socketDescriptor: Int32,
        directions: NativeSocketDirections,
        timeout: Duration
    ) async throws {
        let waiter = SocketReadinessWaiter(
            socketDescriptor: socketDescriptor,
            directions: directions,
            timeout: timeout
        )
        try await waiter.wait()
    }
}

final class NativeSocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var socketDescriptor: Int32

    init(socketDescriptor: Int32) {
        self.socketDescriptor = socketDescriptor
    }

    deinit {
        close()
    }

    func descriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard socketDescriptor >= 0 else {
            throw RemoteOperationError(
                category: .network,
                code: "socket_closed",
                safeDiagnosticMessage: "Native SSH socket is closed"
            )
        }
        return socketDescriptor
    }

    func interrupt() {
        lock.lock()
        let descriptor = socketDescriptor
        lock.unlock()
        if descriptor >= 0 {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    func close() {
        lock.lock()
        let descriptor = socketDescriptor
        socketDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }
}

struct NativeTCPConnector: Sendable {
    private let resolverQueue = DispatchQueue(
        label: "io.lighting-tech.remora.native-ssh.dns",
        qos: .utility,
        attributes: .concurrent
    )

    func connect(
        to endpoint: RemoteEndpoint,
        timeout: Duration,
        diagnostic: @escaping @Sendable (String) -> Void
    ) async throws -> NativeSocketHandle {
        guard !endpoint.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(endpoint.port)
        else {
            throw RemoteOperationError(
                category: .network,
                code: "invalid_endpoint",
                safeDiagnosticMessage: "SSH endpoint hostname or port is invalid"
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let addresses = try await resolve(
            hostname: endpoint.hostname,
            port: endpoint.port,
            timeout: timeout
        )
        diagnostic("resolved addressCount=\(addresses.count)")

        var lastError: RemoteOperationError?
        for (index, address) in addresses.enumerated() {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw timeoutError(operation: "connect")
            }

            do {
                diagnostic("connect attempt=\(index + 1) family=\(address.family)")
                return try await connect(address: address, timeout: remaining)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RemoteOperationError {
                lastError = error
                diagnostic("connect attempt=\(index + 1) failed code=\(error.code) backendCode=\(error.backendCode ?? 0)")
            }
        }

        throw lastError ?? RemoteOperationError(
            category: .network,
            code: "address_unavailable",
            safeDiagnosticMessage: "No usable address was returned for the SSH endpoint"
        )
    }

    private func resolve(hostname: String, port: Int, timeout: Duration) async throws -> [ResolvedSocketAddress] {
        let request = DNSResolutionRequest(
            hostname: hostname,
            service: String(port),
            timeout: timeout,
            queue: resolverQueue
        )
        return try await request.value()
    }

    private func connect(
        address: ResolvedSocketAddress,
        timeout: Duration
    ) async throws -> NativeSocketHandle {
        let descriptor = Darwin.socket(address.family, address.socketType, address.protocolNumber)
        guard descriptor >= 0 else {
            throw socketError(code: "socket_create_failed", backendCode: errno)
        }

        let socket = NativeSocketHandle(socketDescriptor: descriptor)
        do {
            try configureNonblockingSocket(descriptor)
            let result = address.bytes.withUnsafeBytes { rawBuffer -> Int32 in
                guard let baseAddress = rawBuffer.baseAddress else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.connect(
                    descriptor,
                    baseAddress.assumingMemoryBound(to: sockaddr.self),
                    socklen_t(rawBuffer.count)
                )
            }

            if result == 0 {
                return socket
            }
            guard errno == EINPROGRESS else {
                throw socketError(code: "socket_connect_failed", backendCode: errno)
            }

            try await withTaskCancellationHandler {
                try await SocketReadiness.wait(
                    for: descriptor,
                    directions: .outbound,
                    timeout: timeout
                )
            } onCancel: {
                socket.interrupt()
            }

            var connectionError: Int32 = 0
            var optionLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectionError, &optionLength) == 0 else {
                throw socketError(code: "socket_status_failed", backendCode: errno)
            }
            guard connectionError == 0 else {
                throw socketError(code: "socket_connect_failed", backendCode: connectionError)
            }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    private func configureNonblockingSocket(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw socketError(code: "socket_nonblocking_failed", backendCode: errno)
        }

        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0, fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw socketError(code: "socket_close_on_exec_failed", backendCode: errno)
        }
    }
}

private struct ResolvedSocketAddress: Sendable {
    let family: Int32
    let socketType: Int32
    let protocolNumber: Int32
    let bytes: Data
}

private final class DNSResolutionRequest: @unchecked Sendable {
    private let hostname: String
    private let service: String
    private let timeout: Duration
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var continuation: CheckedContinuation<[ResolvedSocketAddress], Error>?
    private var timer: DispatchSourceTimer?
    private var completed = false

    init(hostname: String, service: String, timeout: Duration, queue: DispatchQueue) {
        self.hostname = hostname
        self.service = service
        self.timeout = timeout
        self.queue = queue
    }

    func value() async throws -> [ResolvedSocketAddress] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start(continuation: CheckedContinuation<[ResolvedSocketAddress], Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.finish(.failure(timeoutError(operation: "dns")))
        }
        timer.schedule(deadline: .now() + dispatchInterval(timeout))
        self.timer = timer
        lock.unlock()

        timer.resume()
        queue.async { [weak self] in
            self?.performResolution()
        }
    }

    private func performResolution() {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(hostname, service, &hints, &resultPointer)
        guard result == 0 else {
            finish(.failure(RemoteOperationError(
                category: .network,
                code: "dns_resolution_failed",
                safeDiagnosticMessage: String(cString: gai_strerror(result)),
                backendCode: Int(result)
            )))
            return
        }
        defer { freeaddrinfo(resultPointer) }

        var addresses: [ResolvedSocketAddress] = []
        var cursor = resultPointer
        while let info = cursor?.pointee {
            if let address = info.ai_addr, info.ai_addrlen > 0 {
                addresses.append(
                    ResolvedSocketAddress(
                        family: info.ai_family,
                        socketType: info.ai_socktype,
                        protocolNumber: info.ai_protocol,
                        bytes: Data(bytes: address, count: Int(info.ai_addrlen))
                    )
                )
            }
            cursor = info.ai_next
        }

        guard !addresses.isEmpty else {
            finish(.failure(RemoteOperationError(
                category: .network,
                code: "dns_no_addresses",
                safeDiagnosticMessage: "DNS resolution returned no usable addresses"
            )))
            return
        }
        finish(.success(addresses))
    }

    private func finish(_ result: Result<[ResolvedSocketAddress], Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

private final class SocketReadinessWaiter: @unchecked Sendable {
    private let socketDescriptor: Int32
    private let directions: NativeSocketDirections
    private let timeout: Duration
    private let queue = DispatchQueue(label: "io.lighting-tech.remora.native-ssh.socket-readiness")
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var timer: DispatchSourceTimer?
    private var completed = false

    init(socketDescriptor: Int32, directions: NativeSocketDirections, timeout: Duration) {
        self.socketDescriptor = socketDescriptor
        self.directions = directions.isEmpty ? .both : directions
        self.timeout = timeout
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start(continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation

        if directions.contains(.inbound) {
            let source = DispatchSource.makeReadSource(fileDescriptor: socketDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.finish(.success(())) }
            readSource = source
        }
        if directions.contains(.outbound) {
            let source = DispatchSource.makeWriteSource(fileDescriptor: socketDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.finish(.success(())) }
            writeSource = source
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.finish(.failure(timeoutError(operation: "socket_wait")))
        }
        timer.schedule(deadline: .now() + dispatchInterval(timeout))
        self.timer = timer

        let readSource = self.readSource
        let writeSource = self.writeSource
        lock.unlock()

        readSource?.resume()
        writeSource?.resume()
        timer.resume()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let readSource = self.readSource
        self.readSource = nil
        let writeSource = self.writeSource
        self.writeSource = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        readSource?.setEventHandler {}
        writeSource?.setEventHandler {}
        timer?.setEventHandler {}
        readSource?.cancel()
        writeSource?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

private func socketError(code: String, backendCode: Int32) -> RemoteOperationError {
    RemoteOperationError(
        category: .network,
        code: code,
        safeDiagnosticMessage: String(cString: strerror(backendCode)),
        backendCode: Int(backendCode)
    )
}

private func timeoutError(operation: String) -> RemoteOperationError {
    RemoteOperationError(
        category: .network,
        code: "\(operation)_timeout",
        safeDiagnosticMessage: "Native SSH \(operation) timed out"
    )
}

private func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let components = duration.components
    let seconds = max(0, components.seconds)
    let nanosecondsFromAttoseconds = max(0, components.attoseconds / 1_000_000_000)
    let (secondsNanoseconds, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflowed else { return .never }
    let (total, additionOverflowed) = secondsNanoseconds.addingReportingOverflow(nanosecondsFromAttoseconds)
    guard !additionOverflowed else { return .never }
    return .nanoseconds(Int(clamping: max(1, total)))
}
