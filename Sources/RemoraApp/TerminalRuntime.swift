import Foundation
import RemoraCore
import RemoraTerminal

enum SSHAuthStage: String, Equatable, Sendable {
    case hostKey
    case password
    case otp
    case passphrase
}

enum ConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case local = "Local"
    case ssh = "SSH"

    var id: String { rawValue }
}

struct TerminalConnectConfig: Sendable {
    var mode: ConnectionMode
    var hostAddress: String
    var hostPort: Int
    var username: String
    var authMethod: AuthenticationMethod
    var keyReference: String?
    var passwordReference: String?
}

@MainActor
final class TerminalRuntime: ObservableObject {
    @Published var connectionState: String = "Idle"
    @Published var connectionMode: ConnectionMode = .local
    @Published var transcriptSnapshot: String = ""
    @Published var hostKeyPromptMessage: String?

    private let localSessionManager: SessionManager
    private let sshSessionManager: SessionManager

    private weak var terminalView: TerminalView?
    private var activeSessionManager: SessionManager?
    private var sessionID: UUID?
    private var streamTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var inputDrainerTask: Task<Void, Never>?
    private var pendingInputs: [Data] = []
    private var isPaneActive = true
    private var pendingOutput = Data()
    private var transcriptBuffer = ""
    private let maxTranscriptCharacters = 4_096
    private var pendingPTYSize: PTYSize?
    private var lastAppliedPTYSize: PTYSize?
    private var activeSSHAuthStage: SSHAuthStage?
    private var sshAuthProbeTail = ""
    private var activeSSHHostAddress: String?

    init(
        localSessionManager: SessionManager = SessionManager(sshClientFactory: { LocalShellClient() }),
        sshSessionManager: SessionManager = SessionManager(sshClientFactory: { OpenSSHProcessClient() })
    ) {
        self.localSessionManager = localSessionManager
        self.sshSessionManager = sshSessionManager
    }

    func attach(view: TerminalView) {
        terminalView = view
        view.isDisplayActive = isPaneActive
        view.onInput = { [weak self] data in
            DispatchQueue.main.async {
                self?.enqueueInput(data)
            }
        }
        flushPendingOutputIfNeeded()
    }

    func setPaneActive(_ isActive: Bool) {
        isPaneActive = isActive
        terminalView?.isDisplayActive = isActive
    }

    func connectLocalShell() {
        connect(
            using: TerminalConnectConfig(
                mode: .local,
                hostAddress: "127.0.0.1",
                hostPort: 22,
                username: NSUserName(),
                authMethod: .agent,
                keyReference: nil,
                passwordReference: nil
            )
        )
    }

    func connectSSH(address: String, port: Int, username: String, privateKeyPath: String?) {
        connect(
            using: TerminalConnectConfig(
                mode: .ssh,
                hostAddress: address,
                hostPort: port,
                username: username,
                authMethod: privateKeyPath == nil ? .agent : .privateKey,
                keyReference: privateKeyPath,
                passwordReference: nil
            )
        )
    }

    func connectSSH(host: RemoraCore.Host) {
        connect(
            using: TerminalConnectConfig(
                mode: .ssh,
                hostAddress: host.address,
                hostPort: host.port,
                username: host.username,
                authMethod: host.auth.method,
                keyReference: host.auth.keyReference,
                passwordReference: host.auth.passwordReference
            )
        )
    }

    func connect(using config: TerminalConnectConfig) {
        Task {
            await stopActiveSessionIfNeeded()
            await MainActor.run {
                connectionMode = config.mode
                connectionState = "Connecting"
                clearTranscript()
                clearInputQueue()
            }

            guard let host = await MainActor.run(body: { buildHostConfiguration(config: config) }) else {
                await MainActor.run {
                    connectionState = "配置错误：请检查主机、端口、用户名"
                }
                return
            }

            await MainActor.run {
                activeSSHHostAddress = host.address
            }

            let manager = await MainActor.run(body: { sessionManager(for: config.mode) })

            do {
                let descriptor = try await manager.startSession(
                    for: host,
                    pty: .init(columns: 120, rows: 30)
                )

                await MainActor.run {
                    sessionID = descriptor.id
                    activeSessionManager = manager
                    connectionState = "Connected (\(config.mode.rawValue))"
                    bindOutput(for: descriptor.id, manager: manager)
                    bindSessionState(for: descriptor.id, manager: manager)
                }
                await self.applyPendingResizeIfNeeded()
            } catch {
                await MainActor.run {
                    connectionState = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func disconnect() {
        Task {
            await stopActiveSessionIfNeeded()
            await MainActor.run {
                self.connectionState = "Disconnected"
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        let nextSize = PTYSize(columns: max(1, columns), rows: max(1, rows))
        pendingPTYSize = nextSize
        Task { await applyPendingResizeIfNeeded() }
    }

    func respondToHostKeyPrompt(accept: Bool) {
        enqueueInput(Data((accept ? "yes\n" : "no\n").utf8))
        hostKeyPromptMessage = nil
        activeSSHAuthStage = nil
        sshAuthProbeTail.removeAll(keepingCapacity: false)
        connectionState = accept ? "Waiting (authentication)" : "Host key rejected"
    }

    func dismissHostKeyPrompt() {
        hostKeyPromptMessage = nil
    }

    private func bindOutput(for id: UUID, manager: SessionManager) {
        streamTask?.cancel()
        streamTask = Task {
            let stream = await manager.sessionOutputStream(sessionID: id)
            for await data in stream {
                await MainActor.run {
                    appendTranscript(data)
                    updateAuthenticationState(with: data)
                    if let terminalView {
                        terminalView.feed(data: data)
                    } else {
                        enqueuePendingOutput(data)
                    }
                }
            }
        }
    }

    private func bindSessionState(for id: UUID, manager: SessionManager) {
        stateTask?.cancel()
        stateTask = Task {
            let stream = await manager.sessionStateStream(sessionID: id)
            for await state in stream {
                await MainActor.run {
                    switch state {
                    case .idle:
                        connectionState = "Idle"
                    case .running:
                        if activeSSHAuthStage == nil {
                            connectionState = "Connected (\(connectionMode.rawValue))"
                        }
                    case .stopped:
                        connectionState = "Disconnected"
                        hostKeyPromptMessage = nil
                        activeSSHAuthStage = nil
                    case .failed(let reason):
                        connectionState = "Failed: \(reason)"
                        hostKeyPromptMessage = nil
                        activeSSHAuthStage = nil
                    }
                }
            }
        }
    }

    private func enqueueInput(_ data: Data) {
        pendingInputs.append(data)
        guard inputDrainerTask == nil else { return }

        inputDrainerTask = Task { [weak self] in
            await self?.drainInputQueue()
        }
    }

    private func drainInputQueue() async {
        defer {
            inputDrainerTask = nil
            if !pendingInputs.isEmpty {
                inputDrainerTask = Task { [weak self] in
                    await self?.drainInputQueue()
                }
            }
        }

        while !pendingInputs.isEmpty {
            if Task.isCancelled { return }

            let data = pendingInputs.removeFirst()
            guard !data.isEmpty else { continue }
            guard let sessionID, let manager = activeSessionManager else { continue }

            do {
                try await manager.write(data, to: sessionID)
            } catch {
                connectionState = "Write failed: \(error.localizedDescription)"
                return
            }
        }
    }

    private func clearInputQueue() {
        pendingInputs.removeAll(keepingCapacity: false)
        inputDrainerTask?.cancel()
        inputDrainerTask = nil
    }

    private func sessionManager(for mode: ConnectionMode) -> SessionManager {
        switch mode {
        case .local:
            return localSessionManager
        case .ssh:
            return sshSessionManager
        }
    }

    private func stopActiveSessionIfNeeded() async {
        guard let currentSessionID = sessionID, let manager = activeSessionManager else { return }

        await manager.stopSession(id: currentSessionID)
        sessionID = nil
        activeSessionManager = nil

        streamTask?.cancel()
        streamTask = nil
        stateTask?.cancel()
        stateTask = nil

        pendingOutput.removeAll(keepingCapacity: false)
        clearInputQueue()
        lastAppliedPTYSize = nil
        activeSSHAuthStage = nil
        activeSSHHostAddress = nil
        sshAuthProbeTail.removeAll(keepingCapacity: false)
        hostKeyPromptMessage = nil
    }

    private func applyPendingResizeIfNeeded() async {
        guard let pendingSize = pendingPTYSize else { return }
        guard pendingSize != lastAppliedPTYSize else { return }
        guard let sessionID, let manager = activeSessionManager else { return }

        do {
            try await manager.resize(sessionID: sessionID, pty: pendingSize)
            lastAppliedPTYSize = pendingSize
        } catch {
            connectionState = "Resize failed: \(error.localizedDescription)"
        }
    }

    private func buildHostConfiguration(config: TerminalConnectConfig) -> RemoraCore.Host? {
        let trimmedHost = config.hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else { return nil }
        guard config.hostPort > 0, config.hostPort < 65536 else { return nil }

        let keyPath = config.keyReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordReference = config.passwordReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: HostAuth = {
            switch config.authMethod {
            case .privateKey:
                if let keyPath, !keyPath.isEmpty {
                    return HostAuth(method: .privateKey, keyReference: keyPath)
                }
                return HostAuth(method: .agent)
            case .password:
                if let passwordReference, !passwordReference.isEmpty {
                    return HostAuth(method: .password, passwordReference: passwordReference)
                }
                return HostAuth(method: .password)
            case .agent:
                return HostAuth(method: .agent)
            }
        }()

        return RemoraCore.Host(
            name: trimmedHost,
            address: trimmedHost,
            port: config.hostPort,
            username: trimmedUser,
            auth: auth
        )
    }

    private func enqueuePendingOutput(_ data: Data) {
        pendingOutput.append(data)
        let maxPendingBytes = 512 * 1024
        if pendingOutput.count > maxPendingBytes {
            pendingOutput.removeFirst(pendingOutput.count - maxPendingBytes)
        }
    }

    private func flushPendingOutputIfNeeded() {
        guard let terminalView, !pendingOutput.isEmpty else { return }
        terminalView.feed(data: pendingOutput)
        pendingOutput.removeAll(keepingCapacity: false)
    }

    private func clearTranscript() {
        transcriptBuffer.removeAll(keepingCapacity: false)
        transcriptSnapshot = ""
        pendingOutput.removeAll(keepingCapacity: false)
        activeSSHAuthStage = nil
        sshAuthProbeTail.removeAll(keepingCapacity: false)
        hostKeyPromptMessage = nil
    }

    private func appendTranscript(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return }

        transcriptBuffer.append(chunk)
        if transcriptBuffer.count > maxTranscriptCharacters {
            transcriptBuffer.removeFirst(transcriptBuffer.count - maxTranscriptCharacters)
        }

        transcriptSnapshot = transcriptBuffer
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func updateAuthenticationState(with data: Data) {
        guard connectionMode == .ssh else { return }
        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return }

        let probeText = sshAuthProbeTail + chunk
        let detectedStage = Self.detectSSHAuthStage(in: probeText.lowercased())

        if let detectedStage {
            activeSSHAuthStage = detectedStage
            switch detectedStage {
            case .hostKey:
                connectionState = "Waiting (host-key)"
                if hostKeyPromptMessage == nil {
                    hostKeyPromptMessage = Self.makeHostKeyPromptMessage(
                        from: probeText,
                        hostAddress: activeSSHHostAddress
                    )
                }
            case .password:
                connectionState = "Waiting (password)"
            case .otp:
                connectionState = "Waiting (otp)"
            case .passphrase:
                connectionState = "Waiting (passphrase)"
            }
        } else if activeSSHAuthStage != nil {
            activeSSHAuthStage = nil
            hostKeyPromptMessage = nil
            connectionState = "Connected (\(connectionMode.rawValue))"
        }

        if probeText.count > 512 {
            sshAuthProbeTail = String(probeText.suffix(512))
        } else {
            sshAuthProbeTail = probeText
        }
    }

    static func detectSSHAuthStage(in lowercasedText: String) -> SSHAuthStage? {
        if lowercasedText.contains("are you sure you want to continue connecting"),
           lowercasedText.contains("yes/no")
        {
            return .hostKey
        }

        if lowercasedText.contains("continue connecting"),
           lowercasedText.contains("fingerprint")
        {
            return .hostKey
        }

        if lowercasedText.contains("enter passphrase for key") || lowercasedText.contains("passphrase for key") {
            return .passphrase
        }

        if lowercasedText.contains("one-time password")
            || lowercasedText.contains("verification code:")
            || lowercasedText.contains("otp:")
            || lowercasedText.contains("authenticator code")
            || lowercasedText.contains("token code")
        {
            return .otp
        }

        if lowercasedText.contains("password:") {
            return .password
        }

        return nil
    }

    static func makeHostKeyPromptMessage(from probeText: String, hostAddress: String?) -> String {
        let trimmedHost = hostAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPart: String = {
            if let trimmedHost, !trimmedHost.isEmpty {
                return "Host: \(trimmedHost)\n\n"
            }
            return ""
        }()

        let normalizedLines = probeText
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let relevantLines = normalizedLines.filter { line in
            let lower = line.lowercased()
            return lower.contains("authenticity of host")
                || lower.contains("fingerprint")
                || lower.contains("continue connecting")
                || lower.contains("yes/no")
        }

        if relevantLines.isEmpty {
            return hostPart + "The server is requesting first-time host key confirmation. Verify the fingerprint and choose Trust or Reject."
        }

        let snippet = relevantLines.suffix(4).joined(separator: "\n")
        return hostPart + snippet
    }
}
