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
    @Published private(set) var workingDirectory: String?
    @Published private(set) var connectedSSHHost: RemoraCore.Host?
    @Published private(set) var lastConnectedSSHHost: RemoraCore.Host?

    // Connection state constants for safer string comparisons
    static let connectedPrefix = "Connected"
    static let failedPrefix = "Failed"
    static let connectingState = "Connecting"
    static let waitingPrefix = "Waiting"

    private let localSessionManager: SessionManager
    private let sshSessionManager: SessionManager

    private weak var terminalView: TerminalView?
    private var activeSessionManager: SessionManager?
    private var sessionID: UUID?
    private var streamTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var inputDrainerTask: Task<Void, Never>?
    private var pendingResizeApplyTask: Task<Void, Never>?
    private struct QueuedInput {
        var data: Data
        var trackWorkingDirectory: Bool
    }

    private var pendingInputs: [QueuedInput] = []
    private var isPaneActive = true
    private var pendingOutput = Data()
    private var transcriptBuffer = ""
    private let maxTranscriptCharacters = 4_096
    private var pendingPTYSize: PTYSize?
    private var lastAppliedPTYSize: PTYSize?
    private var isApplyingPendingResize = false
    private var activeSSHAuthStage: SSHAuthStage?
    private var sshAuthProbeTail = ""
    private var activeSSHHostAddress: String?
    private var isWorkingDirectoryTrackingEnabled = false
    private var pendingWorkingDirectoryProbeTask: Task<Void, Never>?
    private var awaitingPwdResponse = false
    private var workingDirectoryLineBuffer = ""

    private var isReconnecting = false
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

    var reconnectableSSHHost: RemoraCore.Host? {
        connectedSSHHost ?? lastConnectedSSHHost
    }

    func reconnectSSHSession() {
        guard !isReconnecting, let host = reconnectableSSHHost else { return }
        isReconnecting = true
        connectSSH(host: host)
    }

    func connect(using config: TerminalConnectConfig) {
        Task {
            await stopActiveSessionIfNeeded()
            await MainActor.run {
                connectionMode = config.mode
                connectionState = "Connecting"
                connectedSSHHost = nil
                clearTranscript()
                clearInputQueue()
                workingDirectory = config.mode == .local ? FileManager.default.currentDirectoryPath : "/"
            }

            guard let host = await MainActor.run(body: { buildHostConfiguration(config: config) }) else {
                await MainActor.run {
                    connectionState = "配置错误：请检查主机、端口、用户名"
                }
                return
            }

            await MainActor.run {
                activeSSHHostAddress = host.address
                if config.mode == .ssh {
                    lastConnectedSSHHost = host
                }
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
                    connectedSSHHost = config.mode == .ssh ? descriptor.host : nil
                    bindOutput(for: descriptor.id, manager: manager)
                    bindSessionState(for: descriptor.id, manager: manager)
                    isReconnecting = false
                }
                await self.applyPendingResizeIfNeeded()
                if await MainActor.run(body: { isWorkingDirectoryTrackingEnabled }) {
                    await MainActor.run {
                        scheduleWorkingDirectoryProbe()
                    }
                }
            } catch {
                await MainActor.run {
                    connectionState = "Failed: \(error.localizedDescription)"
                    connectedSSHHost = nil
                    isReconnecting = false
                }
            }
        }
    }

    func disconnect() {
        Task {
            await stopActiveSessionIfNeeded()
            await MainActor.run {
                self.connectionState = "Disconnected"
                self.workingDirectory = nil
                self.connectedSSHHost = nil
                self.isReconnecting = false
            }
        }
    }

    func setWorkingDirectoryTrackingEnabled(_ enabled: Bool) {
        isWorkingDirectoryTrackingEnabled = enabled
        if enabled {
            scheduleWorkingDirectoryProbe()
        } else {
            pendingWorkingDirectoryProbeTask?.cancel()
            pendingWorkingDirectoryProbeTask = nil
            awaitingPwdResponse = false
            workingDirectoryLineBuffer.removeAll(keepingCapacity: false)
        }
    }

    func changeDirectory(to path: String) {
        let normalized = normalizeDirectoryPath(path)
        workingDirectory = normalized
        let quotedPath = shellSingleQuoted(normalized)
        enqueueInput(Data("cd \(quotedPath)\n".utf8), trackWorkingDirectory: false)
        if isWorkingDirectoryTrackingEnabled {
            scheduleWorkingDirectoryProbe()
        }
    }

    func resize(columns: Int, rows: Int) {
        let nextSize = PTYSize(columns: max(1, columns), rows: max(1, rows))
        pendingPTYSize = nextSize
        pendingResizeApplyTask?.cancel()
        pendingResizeApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            await self.applyPendingResizeIfNeeded()
        }
    }

    func respondToHostKeyPrompt(accept: Bool) {
        enqueueInput(Data((accept ? "yes\n" : "no\n").utf8), trackWorkingDirectory: false)
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
                        connectedSSHHost = nil
                        hostKeyPromptMessage = nil
                        activeSSHAuthStage = nil
                    case .failed(let reason):
                        connectionState = "Failed: \(reason)"
                        connectedSSHHost = nil
                        hostKeyPromptMessage = nil
                        activeSSHAuthStage = nil
                    }
                }
            }
        }
    }

    private func enqueueInput(_ data: Data) {
        enqueueInput(data, trackWorkingDirectory: true)
    }

    private func enqueueInput(_ data: Data, trackWorkingDirectory: Bool) {
        pendingInputs.append(.init(data: data, trackWorkingDirectory: trackWorkingDirectory))
        guard inputDrainerTask == nil else { return }

        inputDrainerTask = Task { [weak self] in
            await self?.drainInputQueue()
        }
    }

    // MARK: - PTY Input Helpers

    /// Send left arrow key (move cursor left)
    func sendLeftArrow(count: Int = 1) {
        let sequence = String(repeating: "\u{001B}[D", count: count)
        enqueueInput(Data(sequence.utf8))
    }

    /// Send right arrow key (move cursor right)
    func sendRightArrow(count: Int = 1) {
        let sequence = String(repeating: "\u{001B}[C", count: count)
        enqueueInput(Data(sequence.utf8))
    }

    /// Send Ctrl-A (move to line start - works in bash/readline)
    func sendCtrlA() {
        enqueueInput(Data([0x01])) // Ctrl-A
    }

    /// Send Ctrl-K (delete to line end - works in bash/readline)
    func sendCtrlK() {
        enqueueInput(Data([0x0B])) // Ctrl-K
    }

    /// Send Ctrl-U (delete entire line)
    func sendCtrlU() {
        enqueueInput(Data([0x15])) // Ctrl-U
    }

    /// Send Delete key
    func sendDelete(count: Int = 1) {
        let sequence = String(repeating: "\u{001B}[3~", count: count)
        enqueueInput(Data(sequence.utf8))
    }

    /// Send text with optional bracketed paste
    func sendText(_ text: String, bracketedPaste: Bool = false) {
        if bracketedPaste {
            let start = "\u{001B}[200~"
            let end = "\u{001B}[201~"
            enqueueInput(Data((start + text + end).utf8))
        } else {
            enqueueInput(Data(text.utf8))
        }
    }

    /// Replace current input line with text and position cursor
    func replaceCurrentInputLine(with text: String, cursorAt relativeIndex: Int? = nil) {
        // Strategy: Ctrl-A + Ctrl-K + paste + Ctrl-A + Right(target)
        sendCtrlA()
        sendCtrlK()
        sendText(text, bracketedPaste: false)
        
        // Go back to start and move to target
        sendCtrlA()
        let targetIndex = relativeIndex ?? text.count
        if targetIndex > 0 {
            sendRightArrow(count: targetIndex)
        }
    }
    
    func setBracketedPasteEnabled(_ enabled: Bool) {
        bracketedPasteEnabled = enabled
    }
    
    private var bracketedPasteEnabled = false

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

            let queuedInput = pendingInputs.removeFirst()
            guard !queuedInput.data.isEmpty else { continue }
            guard let sessionID, let manager = activeSessionManager else { continue }

            do {
                try await manager.write(queuedInput.data, to: sessionID)
                if queuedInput.trackWorkingDirectory,
                   isWorkingDirectoryTrackingEnabled,
                   queuedInput.data.contains(where: { $0 == 10 || $0 == 13 })
                {
                    scheduleWorkingDirectoryProbe()
                }
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
        pendingResizeApplyTask?.cancel()
        pendingResizeApplyTask = nil
        lastAppliedPTYSize = nil
        activeSSHAuthStage = nil
        activeSSHHostAddress = nil
        connectedSSHHost = nil
        sshAuthProbeTail.removeAll(keepingCapacity: false)
        hostKeyPromptMessage = nil
        pendingWorkingDirectoryProbeTask?.cancel()
        pendingWorkingDirectoryProbeTask = nil
        awaitingPwdResponse = false
        workingDirectoryLineBuffer.removeAll(keepingCapacity: false)
    }

    private func applyPendingResizeIfNeeded() async {
        guard !isApplyingPendingResize else { return }
        isApplyingPendingResize = true
        defer { isApplyingPendingResize = false }

        while true {
            guard let pendingSize = pendingPTYSize else { return }
            guard pendingSize != lastAppliedPTYSize else { return }
            guard let sessionID, let manager = activeSessionManager else { return }

            do {
                try await manager.resize(sessionID: sessionID, pty: pendingSize)
                lastAppliedPTYSize = pendingSize
            } catch {
                connectionState = "Resize failed: \(error.localizedDescription)"
                return
            }
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

        updateWorkingDirectory(with: chunk)

        transcriptBuffer.append(chunk)
        if transcriptBuffer.count > maxTranscriptCharacters {
            transcriptBuffer.removeFirst(transcriptBuffer.count - maxTranscriptCharacters)
        }

        transcriptSnapshot = transcriptBuffer
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func scheduleWorkingDirectoryProbe() {
        guard isWorkingDirectoryTrackingEnabled else { return }
        pendingWorkingDirectoryProbeTask?.cancel()
        pendingWorkingDirectoryProbeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.sessionID != nil else { return }
            await MainActor.run {
                self.awaitingPwdResponse = true
                self.enqueueInput(Data("pwd\n".utf8), trackWorkingDirectory: false)
            }
        }
    }

    private func updateWorkingDirectory(with chunk: String) {
        guard isWorkingDirectoryTrackingEnabled else { return }
        if let oscPath = parseOSC7Path(from: chunk) {
            workingDirectory = normalizeDirectoryPath(oscPath)
            awaitingPwdResponse = false
        }

        let normalizedChunk = chunk.replacingOccurrences(of: "\r", with: "\n")
        workingDirectoryLineBuffer.append(normalizedChunk)

        while let newlineIndex = workingDirectoryLineBuffer.firstIndex(of: "\n") {
            let rawLine = String(workingDirectoryLineBuffer[..<newlineIndex])
            workingDirectoryLineBuffer.removeSubrange(...newlineIndex)

            guard awaitingPwdResponse else { continue }
            guard let candidatePath = extractWorkingDirectoryPath(from: rawLine) else { continue }
            workingDirectory = normalizeDirectoryPath(candidatePath)
            awaitingPwdResponse = false
        }

        if workingDirectoryLineBuffer.count > 2048 {
            workingDirectoryLineBuffer = String(workingDirectoryLineBuffer.suffix(1024))
        }
    }

    private func parseOSC7Path(from text: String) -> String? {
        let oscPrefix = "\u{001B}]7;file://"
        guard let prefixRange = text.range(of: oscPrefix) else { return nil }
        let remainder = text[prefixRange.upperBound...]
        let terminatorIndex: String.Index? = remainder.firstIndex(of: "\u{0007}")
            ?? remainder.range(of: "\u{001B}\\")?.lowerBound
        guard let terminatorIndex else { return nil }
        let payload = String(remainder[..<terminatorIndex])
        guard let slashIndex = payload.firstIndex(of: "/") else { return nil }
        let path = String(payload[slashIndex...])
        return path.removingPercentEncoding ?? path
    }

    private func extractWorkingDirectoryPath(from rawLine: String) -> String? {
        let stripped = stripANSISequences(from: rawLine)
            .unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0) || $0 == "\t" || $0 == "\n" || $0 == "\r"
            }
            .map(Character.init)
        let normalizedLine = String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLine.isEmpty else { return nil }
        if normalizedLine == "pwd" { return nil }

        if normalizedLine.hasPrefix("/") {
            return normalizedLine
        }

        for token in normalizedLine.split(whereSeparator: { $0.isWhitespace }) {
            guard token.first == "/" else { continue }
            return String(token)
        }
        return nil
    }

    private func stripANSISequences(from text: String) -> String {
        var output = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            // ESC-prefixed control sequence.
            if scalar == "\u{001B}" {
                let nextIndex = index + 1
                guard nextIndex < scalars.count else { break }
                let marker = scalars[nextIndex]

                // CSI: ESC [ ... final byte
                if marker == "[" {
                    index = nextIndex + 1
                    while index < scalars.count {
                        let byte = scalars[index].value
                        if (0x40...0x7E).contains(byte) {
                            index += 1
                            break
                        }
                        index += 1
                    }
                    continue
                }

                // OSC: ESC ] ... BEL or ESC \
                if marker == "]" {
                    index = nextIndex + 1
                    while index < scalars.count {
                        if scalars[index] == "\u{0007}" {
                            index += 1
                            break
                        }
                        if scalars[index] == "\u{001B}" {
                            let maybeTerminator = index + 1
                            if maybeTerminator < scalars.count, scalars[maybeTerminator] == "\\" {
                                index = maybeTerminator + 1
                                break
                            }
                        }
                        index += 1
                    }
                    continue
                }

                // Unsupported ESC sequence, skip marker.
                index = nextIndex + 1
                continue
            }

            // Single-byte CSI (C1 control).
            if scalar == "\u{009B}" {
                index += 1
                while index < scalars.count {
                    let byte = scalars[index].value
                    if (0x40...0x7E).contains(byte) {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }

            output.unicodeScalars.append(scalar)
            index += 1
        }

        return output
    }

    private func normalizeDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return prefixed.replacingOccurrences(of: "//", with: "/")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
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
