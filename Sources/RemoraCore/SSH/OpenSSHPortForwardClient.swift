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

    public static func isPortAvailable(address: String, port: Int) -> Bool {
        guard isValidPort(port) else { return false }
        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            let host = normalizedHost(address)
            if host != "*" && host != "0.0.0.0" && host != "::" {
                parameters.requiredLocalEndpoint = .hostPort(host: .init(host), port: .init(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port)))
            }
            listener = try NWListener(using: parameters, on: .init(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port)))
        } catch {
            return false
        }
        listener.cancel()
        return true
    }

    public static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    static func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class OpenSSHPortForwardProcess: @unchecked Sendable {
    public var onStateChange: (@Sendable (PortForwardState) -> Void)?

    private let host: Host
    private let preset: HostPortForwardPreset
    private let compatibilityProfileStore: SSHCompatibilityProfileStore
    private let credentialStore: CredentialStore
    private var process: Process?
    private var outputPipe: Pipe?
    private let stateQueue = DispatchQueue(label: "io.lighting-tech.remora.port-forward")
    private var failureBuffer = Data()
    private let failureBufferLimit = 16 * 1024

    public init(host: Host, preset: HostPortForwardPreset) {
        self.host = host
        self.preset = preset
        self.compatibilityProfileStore = .shared
        self.credentialStore = CredentialStore()
    }

    public func start() async throws {
        if let error = PortForwardValidation.validate(preset) {
            onStateChange?(.failed(error))
            throw SSHError.connectionFailed(error)
        }
        guard PortForwardValidation.isPortAvailable(address: preset.localAddress, port: preset.localPort) else {
            let message = "Local port \(preset.localPort) is already in use"
            onStateChange?(.failed(message))
            throw SSHError.connectionFailed(message)
        }

        onStateChange?(.starting)
        let compatibilityProfile = await compatibilityProfileStore.cachedProfile(for: host) ?? SSHCompatibilityProfile()
        let storedPassword: String? = if host.auth.method == .password,
                                         let passwordReference = host.auth.passwordReference,
                                         !passwordReference.isEmpty,
                                         let password = await credentialStore.secret(for: passwordReference),
                                         !password.isEmpty {
            password
        } else {
            nil
        }

        guard let launch = OpenSSHLaunchBuilder.makePortForwardLaunchConfiguration(
            for: host,
            preset: preset,
            storedPassword: storedPassword,
            compatibilityProfile: compatibilityProfile
        ) else {
            let message = "Unable to build SSH port forward command"
            onStateChange?(.failed(message))
            throw SSHError.connectionFailed(message)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executablePath)
        process.arguments = launch.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.stateQueue.sync {
                self.failureBuffer.append(data)
                if self.failureBuffer.count > self.failureBufferLimit {
                    self.failureBuffer = self.failureBuffer.suffix(self.failureBufferLimit)
                }
            }
        }

        process.terminationHandler = { [weak self] task in
            guard let self else { return }
            self.cleanup()
            if task.terminationStatus == 0 {
                self.onStateChange?(.stopped)
                return
            }
            let output = self.stateQueue.sync { String(decoding: self.failureBuffer, as: UTF8.self) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = output.isEmpty ? "ssh exited with status \(task.terminationStatus)" : output
            self.onStateChange?(.failed(message))
        }

        do {
            try process.run()
        } catch {
            cleanup()
            onStateChange?(.failed(error.localizedDescription))
            throw SSHError.connectionFailed(error.localizedDescription)
        }

        stateQueue.sync {
            self.process = process
            self.outputPipe = pipe
            self.failureBuffer.removeAll(keepingCapacity: true)
        }
        onStateChange?(.running)
    }

    public func stop() {
        let process = stateQueue.sync { self.process }
        guard let process else {
            cleanup()
            onStateChange?(.stopped)
            return
        }
        if process.isRunning {
            process.terminate()
        } else {
            cleanup()
            onStateChange?(.stopped)
        }
    }

    private func cleanup() {
        let pipe = stateQueue.sync { () -> Pipe? in
            let pipe = outputPipe
            outputPipe = nil
            process = nil
            return pipe
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
    }
}
