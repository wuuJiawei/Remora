import Foundation
import RemoraCore
import RemoraTerminal

enum SSHAuthStage: String, Equatable, Sendable {
    case hostKey
    case password
    case otp
    case passphrase
    case keyboardInteractive
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
    var sourceHost: RemoraCore.Host?
}

@MainActor
final class TerminalRuntime: ObservableObject {
    @Published var connectionState: String = "Idle"
    @Published var connectionMode: ConnectionMode = .local
    @Published var transcriptSnapshot: String = ""
    @Published var hostKeyPromptMessage: String?
    @Published var otpPromptMessage: String?
    @Published var passwordPromptMessage: String?
    @Published private(set) var keyboardInteractiveChallenge: KeyboardInteractiveChallenge?
    @Published private(set) var isPrivateKeyPassphrasePrompt = false
    @Published private(set) var workingDirectory: String?
    @Published private(set) var connectedSSHHost: RemoraCore.Host?
    @Published private(set) var lastConnectedSSHHost: RemoraCore.Host?
    @Published private(set) var remoteSessionIdentity: RemoteSessionIdentitySnapshot?

    // Connection state constants for safer string comparisons
    static let connectedPrefix = "Connected"
    static let failedPrefix = "Failed"
    static let connectingState = "Connecting"
    static let waitingPrefix = "Waiting"

    private let localSessionManager: SessionManager
    private let sshSessionManager: SessionManager
    private let nativeInteractionBroker: NativeSessionInteractionBroker

    private weak var terminalView: TerminalView?
    private var activeSessionManager: SessionManager?
    private var sessionID: UUID?
    private var streamTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var inputDrainerTask: Task<Void, Never>?
    private var pendingResizeApplyTask: Task<Void, Never>?
    private var outputFlushTask: Task<Void, Never>?
    private struct QueuedInput {
        var data: Data
        var trackWorkingDirectory: Bool
    }

    private var pendingInputs: [QueuedInput] = []
    private var isPaneActive = true
    private var pendingOutput = Data()
    private var outputBatchBuffer = Data()
    private var outputBatchSessionID: UUID?
    private var promptBoundaryProcessor = TerminalPromptBoundaryProcessor()
    private var transcriptBuffer = ""
    private let maxTranscriptCharacters = 4_096
    private var transcriptRefreshTask: Task<Void, Never>?
    private var pendingPTYSize: PTYSize?
    private var lastAppliedPTYSize: PTYSize?
    private var isApplyingPendingResize = false
    private var activeSSHAuthStage: SSHAuthStage?
    private var activeSSHHostAddress: String?
    private var displayEndsAtLineStart = true
    private var isWorkingDirectoryTrackingEnabled = false
    private var pendingWorkingDirectoryProbeTask: Task<Void, Never>?
    private var awaitingPwdResponse = false
    private var workingDirectoryLineBuffer = ""

    // MARK: - ZMODEM
    private var zmodemDetector = ZmodemDetector()
    private(set) var zmodemCoordinator = ZmodemTransferCoordinator()

    private var isReconnecting = false
    private var terminalInputReconnectEnabled = false
    private var intentionallyStoppedSessionIDs: Set<UUID> = []
    private var nativeInteractionTask: Task<Void, Never>?
    private var pendingNativeHostKeyChallengeID: UUID?
    private var pendingNativeCredentialChallengeID: UUID?
    private var pendingNativeKeyboardChallengeID: UUID?
    init(
        localSessionManager: SessionManager = SessionManager(
            localShellFactory: { host, pty in LocalShellSession(host: host, pty: pty) }
        ),
        sshSessionManager: SessionManager? = nil,
        remoteSessionHub: RemoteSessionHub = .shared,
        nativeInteractionBroker: NativeSessionInteractionBroker = NativeSessionInteractionBroker()
    ) {
        self.localSessionManager = localSessionManager
        self.nativeInteractionBroker = nativeInteractionBroker
        if let sshSessionManager {
            self.sshSessionManager = sshSessionManager
        } else {
            let connector = NativeDirectSessionConnector(
                interactionBroker: nativeInteractionBroker
            ) { event in
                let backendCode = event.backendCode.map(String.init) ?? "none"
                LogManager.debug(
                    .ssh,
                    "native connection=\(event.connectionID.uuidString) phase=\(event.phase.rawValue) operation=\(event.operation) backendCode=\(backendCode) detail=\(event.message)"
                )
            }
            self.sshSessionManager = SessionManager(remoteSessionHub: remoteSessionHub) { host in
                try connector.request(for: host)
            }
        }
        bindNativeInteractionEvents()
    }

    func attach(view: TerminalView) {
        if terminalView !== view {
            terminalView = view
            view.onInput = { [weak self] data in
                DispatchQueue.main.async {
                    self?.handleTerminalInput(data)
                }
            }
        }
        flushPendingOutputIfNeeded()
    }

    func setPaneActive(_ isActive: Bool) {
        isPaneActive = isActive
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
                passwordReference: nil,
                sourceHost: nil
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
                passwordReference: nil,
                sourceHost: nil
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
                passwordReference: host.auth.passwordReference,
                sourceHost: host
            )
        )
    }

    var reconnectableSSHHost: RemoraCore.Host? {
        connectedSSHHost ?? lastConnectedSSHHost
    }

    func reconnectSSHSession() {
        guard !isReconnecting, let host = reconnectableSSHHost else { return }
        isReconnecting = true
        terminalInputReconnectEnabled = false
        connectSSH(host: host)
    }

    func connect(using config: TerminalConnectConfig) {
        if config.mode == .ssh {
            LogManager.info(
                .ssh,
                "connect requested host=\(config.hostAddress) port=\(config.hostPort) user=\(config.username) auth=\(config.authMethod.rawValue) passwordReferencePresent=\(config.passwordReference?.isEmpty == false)"
            )
        }
        Task {
            await stopActiveSessionIfNeeded()
            await MainActor.run {
                connectionMode = config.mode
                connectionState = "Connecting"
                connectedSSHHost = nil
                terminalInputReconnectEnabled = false
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
                    remoteSessionIdentity = descriptor.remoteSessionIdentity
                    connectionState = "Connected (\(config.mode.rawValue))"
                    connectedSSHHost = config.mode == .ssh ? descriptor.host : nil
                    bindOutput(for: descriptor.id, manager: manager)
                    bindSessionState(for: descriptor.id, manager: manager)
                    isReconnecting = false
                    if config.mode == .ssh {
                        LogManager.info(
                            .ssh,
                            "session started id=\(descriptor.id.uuidString) transport=native remoteSession=\(descriptor.remoteSessionIdentity?.sessionID.uuidString ?? "none")"
                        )
                    }
                }
                await self.applyPendingResizeIfNeeded()
            } catch {
                await MainActor.run {
                    connectionState = "Failed: \(error.localizedDescription)"
                    connectedSSHHost = nil
                    isReconnecting = false
                    if config.mode == .ssh {
                        if let operationError = error as? RemoteOperationError {
                            LogManager.error(
                                .ssh,
                                "session start failed category=\(operationError.category.rawValue) code=\(operationError.code) backendCode=\(operationError.backendCode.map(String.init) ?? "none") detail=\(operationError.safeDiagnosticMessage)"
                            )
                        } else {
                            LogManager.error(
                                .ssh,
                                "session start failed category=\(Self.failureCategory(error.localizedDescription))"
                            )
                        }
                    }
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
                self.terminalInputReconnectEnabled = false
            }
        }
    }

    func setWorkingDirectoryTrackingEnabled(_ enabled: Bool) {
        isWorkingDirectoryTrackingEnabled = enabled
        if !enabled {
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
    }

    func resize(columns: Int, rows: Int) {
        let nextSize = PTYSize(columns: max(1, columns), rows: max(1, rows))
        if pendingPTYSize == nextSize || lastAppliedPTYSize == nextSize {
            return
        }
        pendingPTYSize = nextSize
        pendingResizeApplyTask?.cancel()
        pendingResizeApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            await self.applyPendingResizeIfNeeded()
        }
    }

    func respondToHostKeyPrompt(accept: Bool) {
        LogManager.info(.ssh, "auth prompt response stage=hostKey accepted=\(accept)")
        guard let challengeID = pendingNativeHostKeyChallengeID else { return }
        _ = nativeInteractionBroker.respondToHostKey(id: challengeID, accept: accept)
        pendingNativeHostKeyChallengeID = nil
        hostKeyPromptMessage = nil
        activeSSHAuthStage = nil
        connectionState = accept ? "Waiting (authentication)" : "Host key rejected"
    }

    func dismissHostKeyPrompt() {
        LogManager.info(.ssh, "auth prompt dismissed stage=hostKey")
        if let challengeID = pendingNativeHostKeyChallengeID {
            _ = nativeInteractionBroker.respondToHostKey(id: challengeID, accept: false)
            pendingNativeHostKeyChallengeID = nil
        }
        hostKeyPromptMessage = nil
    }

    func respondToOTPPrompt(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let challengeID = pendingNativeKeyboardChallengeID else { return }
        LogManager.info(.ssh, "auth prompt response stage=otp valuePresent=true")
        _ = nativeInteractionBroker.respondToKeyboardInteractive(
            id: challengeID,
            responses: [trimmed]
        )
        pendingNativeKeyboardChallengeID = nil
        keyboardInteractiveChallenge = nil
        otpPromptMessage = nil
        activeSSHAuthStage = nil
        connectionState = "Waiting (authentication)"
    }

    func dismissOTPPrompt() {
        LogManager.info(.ssh, "auth prompt cancelled stage=otp disconnecting=true")
        nativeInteractionBroker.cancelPending()
        pendingNativeKeyboardChallengeID = nil
        keyboardInteractiveChallenge = nil
        otpPromptMessage = nil
        disconnect()
    }

    func respondToPasswordPrompt(password: String) {
        guard !password.isEmpty else { return }
        LogManager.info(.ssh, "auth prompt response stage=password valuePresent=true")
        if let challengeID = pendingNativeCredentialChallengeID {
            _ = nativeInteractionBroker.respondToCredential(id: challengeID, value: password)
            pendingNativeCredentialChallengeID = nil
            isPrivateKeyPassphrasePrompt = false
            passwordPromptMessage = nil
            activeSSHAuthStage = nil
            connectionState = "Waiting (authentication)"
            return
        }
        if let challengeID = pendingNativeKeyboardChallengeID {
            _ = nativeInteractionBroker.respondToKeyboardInteractive(
                id: challengeID,
                responses: [password]
            )
            pendingNativeKeyboardChallengeID = nil
            keyboardInteractiveChallenge = nil
            passwordPromptMessage = nil
            activeSSHAuthStage = nil
            connectionState = "Waiting (authentication)"
            return
        }
    }

    func dismissPasswordPrompt() {
        LogManager.info(.ssh, "auth prompt dismissed stage=password")
        if pendingNativeCredentialChallengeID != nil || pendingNativeKeyboardChallengeID != nil {
            nativeInteractionBroker.cancelPending()
            pendingNativeCredentialChallengeID = nil
            pendingNativeKeyboardChallengeID = nil
            keyboardInteractiveChallenge = nil
            isPrivateKeyPassphrasePrompt = false
        }
        passwordPromptMessage = nil
    }

    @discardableResult
    func respondToKeyboardInteractivePrompt(responses: [String]) -> Bool {
        guard let challenge = keyboardInteractiveChallenge,
              challenge.prompts.count == responses.count else {
            return false
        }
        guard nativeInteractionBroker.respondToKeyboardInteractive(
            id: challenge.id,
            responses: responses
        ) else {
            LogManager.error(
                .ssh,
                "auth prompt response rejected stage=keyboardInteractive challenge=\(challenge.id.uuidString) disconnecting=true"
            )
            pendingNativeKeyboardChallengeID = nil
            keyboardInteractiveChallenge = nil
            disconnect()
            return false
        }
        LogManager.info(
            .ssh,
            "auth prompt response stage=keyboardInteractive challenge=\(challenge.id.uuidString) responses=\(responses.count)"
        )
        pendingNativeKeyboardChallengeID = nil
        keyboardInteractiveChallenge = nil
        activeSSHAuthStage = nil
        connectionState = "Waiting (authentication)"
        return true
    }

    func dismissKeyboardInteractivePrompt() {
        guard keyboardInteractiveChallenge != nil else { return }
        LogManager.info(.ssh, "auth prompt cancelled stage=keyboardInteractive disconnecting=true")
        nativeInteractionBroker.cancelPending()
        pendingNativeKeyboardChallengeID = nil
        keyboardInteractiveChallenge = nil
        disconnect()
    }

    // PTY Debug Logging
    private static let ptyDebugQueue = DispatchQueue(label: "io.lighting-tech.remora.pty-diagnostics")
    private static let ptyDebugEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["REMORA_PTY_DEBUG"]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }()
    private static let ptyDebugTimestampFormatter = ISO8601DateFormatter()
    private static let ptyDebugLogURL: URL = {
        let fm = FileManager.default
        let baseDirectory = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Remora", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("Remora", isDirectory: true)
        try? fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("pty-diagnostics.log")
    }()
    
    private static func logPTYDebug(_ message: String) {
        guard ptyDebugEnabled else { return }
        let timestamp = ptyDebugTimestampFormatter.string(from: Date())
        let data = Data(("[\(timestamp)] \(message)\n").utf8)
        let logURL = ptyDebugLogURL
        ptyDebugQueue.async {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    return
                }
            }
            try? data.write(to: logURL, options: [.atomic])
        }
    }
    
    private var _debugChunkCount = 0
    private var _debugESCDetected = false
    private var _debugPostESCCount = 0
    private let _maxDebugChunks = 30
    private let _maxPostESCChunks = 10
    private let outputCoalesceMaxBytes = 64 * 1024
    private let outputCoalesceFrame = Duration.milliseconds(16)
    
    private func bindOutput(for id: UUID, manager: SessionManager) {
        streamTask?.cancel()
        outputFlushTask?.cancel()
        outputFlushTask = nil
        outputBatchBuffer.removeAll(keepingCapacity: false)
        outputBatchSessionID = id
        _debugChunkCount = 0
        _debugESCDetected = false
        _debugPostESCCount = 0
        streamTask = Task {
            let stream = await manager.sessionOutputStream(sessionID: id)

            for await data in stream {
                if Task.isCancelled { break }
                // Debug: Log first 30 chunks, then continue 10 more after ESC detected
                let shouldLog = Self.ptyDebugEnabled
                    && (_debugChunkCount < _maxDebugChunks || (_debugESCDetected && _debugPostESCCount < _maxPostESCChunks))
                if shouldLog {
                    let maxBytes = min(data.count, 256)
                    let chunk = data.prefix(maxBytes)
                    let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let ascii = String(data: Data(chunk), encoding: .utf8) ?? "(non-utf8)"
                    let hasESC = chunk.contains(0x1B)
                    
                    if hasESC && !_debugESCDetected {
                        _debugESCDetected = true
                        Self.logPTYDebug("========== ESC DETECTED - Will capture more ==========")
                    }
                    
                    let label = _debugESCDetected ? "POST-ESC" : "PRE-ESC"
                    Self.logPTYDebug("-------- PTY #\(_debugChunkCount) [\(label)] (first \(maxBytes) bytes) --------")
                    Self.logPTYDebug("HEX: \(hex)")
                    Self.logPTYDebug("ASCII: \(ascii)")
                    _debugChunkCount += 1
                    if _debugESCDetected {
                        _debugPostESCCount += 1
                    }
                }

                enqueueOutputChunk(data, for: id)
            }

            flushPendingOutputBatch(for: id)
        }
    }

    private func flushOutputBatch(_ data: Data) {
        guard !data.isEmpty else { return }

        if zmodemCoordinator.isActive {
            let trailing = zmodemCoordinator.feedOutput(data)
            if !trailing.isEmpty {
                flushOutputBatch(trailing)
            }
            return
        }

        if zmodemCoordinator.finished {
            zmodemDetector.reset()
            zmodemCoordinator.finished = false
        }

        let result = zmodemDetector.feed(data)
        if let trigger = result.trigger {
            if !result.passthrough.isEmpty {
                let tokens = promptBoundaryProcessor.process(result.passthrough)
                for token in tokens {
                    switch token {
                    case .promptStart:
                        injectPromptLineBreakIfNeeded()
                    case .output(let payload):
                        deliverOutputPayload(payload)
                    }
                }
            }
            handleZmodemTrigger(trigger, trailingData: result.trailingData)
            return
        }

        let tokens = promptBoundaryProcessor.process(data)
        for token in tokens {
            switch token {
            case .promptStart:
                injectPromptLineBreakIfNeeded()
            case .output(let payload):
                deliverOutputPayload(payload)
            }
        }
    }

    private func deliverOutputPayload(_ data: Data) {
        guard !data.isEmpty else { return }
        appendTranscript(data)
        if let terminalView {
            terminalView.feed(data: data)
            displayEndsAtLineStart = terminalView.isCursorAtLineStart
        } else {
            enqueuePendingOutput(data)
            updateDisplayLineState(with: data)
        }
    }

    private func injectPromptLineBreakIfNeeded() {
        let shouldInsertLineBreak: Bool = if let terminalView {
            !terminalView.isCursorAtLineStart
        } else {
            !displayEndsAtLineStart
        }

        guard shouldInsertLineBreak else { return }
        deliverOutputPayload(Data("\r\n".utf8))
    }

    private func handleZmodemTrigger(_ trigger: ZmodemTrigger, trailingData: Data) {
        let writer: (Data) async throws -> Void = { [weak self] data in
            guard let self else { return }
            let sid = await MainActor.run { self.sessionID }
            let mgr = await MainActor.run { self.activeSessionManager }
            guard let sid, let mgr else { return }
            try await mgr.write(data, to: sid)
        }

        switch trigger {
        case .download:
            zmodemCoordinator.startReceive(initialData: trailingData, writer: writer)
        case .upload:
            zmodemCoordinator.startSend(initialData: trailingData, writer: writer)
        }
    }

    private func enqueueOutputChunk(_ data: Data, for sessionID: UUID) {
        guard !data.isEmpty else { return }
        if outputBatchSessionID != sessionID {
            outputBatchBuffer.removeAll(keepingCapacity: false)
            outputBatchSessionID = sessionID
        }

        outputBatchBuffer.append(data)
        if isPaneActive {
            flushPendingOutputBatch(for: sessionID)
            return
        }
        if outputBatchBuffer.count >= outputCoalesceMaxBytes {
            flushPendingOutputBatch(for: sessionID)
            return
        }
        scheduleOutputFlush(for: sessionID)
    }

    private func scheduleOutputFlush(for sessionID: UUID) {
        guard outputFlushTask == nil else { return }
        let delay = outputCoalesceFrame
        outputFlushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushPendingOutputBatch(for: sessionID)
        }
    }

    private func flushPendingOutputBatch(for sessionID: UUID) {
        outputFlushTask?.cancel()
        outputFlushTask = nil

        guard outputBatchSessionID == sessionID else { return }
        guard !outputBatchBuffer.isEmpty else { return }

        let payload = outputBatchBuffer
        outputBatchBuffer.removeAll(keepingCapacity: true)
        flushOutputBatch(payload)
    }

    private func bindSessionState(for id: UUID, manager: SessionManager) {
        stateTask?.cancel()
        stateTask = Task {
            defer {
                Task { @MainActor [weak self] in
                    self?.intentionallyStoppedSessionIDs.remove(id)
                }
            }

            let stream = await manager.sessionStateStream(sessionID: id)
            for await state in stream {
                await MainActor.run {
                    let authStageBeforeStateChange = activeSSHAuthStage?.rawValue ?? "none"
                    switch state {
                    case .idle:
                        LogManager.debug(
                            .ssh,
                            "session state id=\(id.uuidString) state=idle authStage=\(authStageBeforeStateChange)"
                        )
                        connectionState = "Idle"
                    case .running:
                        LogManager.debug(
                            .ssh,
                            "session state id=\(id.uuidString) state=running authStage=\(authStageBeforeStateChange)"
                        )
                        if activeSSHAuthStage == nil {
                            connectionState = "Connected (\(connectionMode.rawValue))"
                        }
                    case .stopped:
                        let wasIntentionallyStopped = intentionallyStoppedSessionIDs.remove(id) != nil
                        LogManager.info(
                            .ssh,
                            "session state id=\(id.uuidString) state=stopped intentional=\(wasIntentionallyStopped) authStage=\(authStageBeforeStateChange) passwordDialogVisible=\(passwordPromptMessage != nil)"
                        )
                        connectionState = "Disconnected"
                        connectedSSHHost = nil
                        terminalInputReconnectEnabled = !wasIntentionallyStopped
                            && connectionMode == .ssh
                            && reconnectableSSHHost != nil
                        hostKeyPromptMessage = nil
                        otpPromptMessage = nil
                        passwordPromptMessage = nil
                        keyboardInteractiveChallenge = nil
                        activeSSHAuthStage = nil
                    case .failed(let reason):
                        let wasIntentionallyStopped = intentionallyStoppedSessionIDs.remove(id) != nil
                        LogManager.error(
                            .ssh,
                            "session state id=\(id.uuidString) state=failed category=\(Self.failureCategory(reason)) intentional=\(wasIntentionallyStopped) authStage=\(authStageBeforeStateChange) passwordDialogVisible=\(passwordPromptMessage != nil)"
                        )
                        connectionState = "Failed: \(reason)"
                        connectedSSHHost = nil
                        terminalInputReconnectEnabled = !wasIntentionallyStopped
                            && connectionMode == .ssh
                            && reconnectableSSHHost != nil
                        hostKeyPromptMessage = nil
                        otpPromptMessage = nil
                        passwordPromptMessage = nil
                        keyboardInteractiveChallenge = nil
                        activeSSHAuthStage = nil
                    }
                }
            }
        }
    }

    private func handleTerminalInput(_ data: Data) {
        guard !data.isEmpty else { return }
        if shouldReconnectFromTerminalInput {
            clearInputQueue()
            reconnectSSHSession()
            return
        }
        enqueueInput(data)
    }

    private var shouldReconnectFromTerminalInput: Bool {
        connectionMode == .ssh
            && terminalInputReconnectEnabled
            && reconnectableSSHHost != nil
            && !isReconnecting
            && !zmodemCoordinator.isActive
    }

    private func enqueueInput(_ data: Data) {
        enqueueInput(data, trackWorkingDirectory: true)
    }

    private func enqueueInput(_ data: Data, trackWorkingDirectory: Bool) {
        if zmodemCoordinator.isActive { return }

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

    func insertAssistantCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        replaceCurrentInputLine(with: trimmed)
    }

    func runAssistantCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueueInput(Data("\(trimmed)\n".utf8))
    }

    func clearScreen() {
        runAssistantCommand("clear")
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
            } catch {
                connectionState = "Write failed: \(error.localizedDescription)"
                connectedSSHHost = nil
                terminalInputReconnectEnabled = connectionMode == .ssh && reconnectableSSHHost != nil
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
        nativeInteractionBroker.cancelPending()
        pendingNativeHostKeyChallengeID = nil
        pendingNativeCredentialChallengeID = nil
        pendingNativeKeyboardChallengeID = nil
        keyboardInteractiveChallenge = nil
        isPrivateKeyPassphrasePrompt = false
        guard let currentSessionID = sessionID, let manager = activeSessionManager else { return }

        intentionallyStoppedSessionIDs.insert(currentSessionID)
        await manager.stopSession(id: currentSessionID)
        sessionID = nil
        activeSessionManager = nil

        streamTask?.cancel()
        streamTask = nil
        stateTask?.cancel()
        stateTask = nil
        outputFlushTask?.cancel()
        outputFlushTask = nil

        pendingOutput.removeAll(keepingCapacity: false)
        outputBatchBuffer.removeAll(keepingCapacity: false)
        outputBatchSessionID = nil
        promptBoundaryProcessor = TerminalPromptBoundaryProcessor()
        clearInputQueue()
        pendingResizeApplyTask?.cancel()
        pendingResizeApplyTask = nil
        lastAppliedPTYSize = nil
        displayEndsAtLineStart = true
        activeSSHAuthStage = nil
        activeSSHHostAddress = nil
        connectedSSHHost = nil
        remoteSessionIdentity = nil
        hostKeyPromptMessage = nil
        otpPromptMessage = nil
        passwordPromptMessage = nil
        keyboardInteractiveChallenge = nil
        isPrivateKeyPassphrasePrompt = false
        pendingWorkingDirectoryProbeTask?.cancel()
        pendingWorkingDirectoryProbeTask = nil
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        awaitingPwdResponse = false
        workingDirectoryLineBuffer.removeAll(keepingCapacity: false)
        zmodemDetector.reset()
        if zmodemCoordinator.isActive {
            zmodemCoordinator.cancelTransfer()
        }
    }

    func acquireRemoteSessionLease() async throws -> any RemoteSessionLeaseProtocol {
        guard let sessionID, let activeSessionManager else {
            throw RemoteOperationError(
                category: .session,
                code: "terminal_session_unavailable",
                safeDiagnosticMessage: "Terminal does not have an active remote session"
            )
        }
        return try await activeSessionManager.acquireRemoteSessionLease(sessionID: sessionID)
    }

    private func bindNativeInteractionEvents() {
        nativeInteractionTask = Task { [weak self, nativeInteractionBroker] in
            for await event in nativeInteractionBroker.events() {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .hostKey(let challenge):
                    pendingNativeHostKeyChallengeID = challenge.id
                    activeSSHAuthStage = .hostKey
                    connectionState = "Waiting (host-key)"
                    hostKeyPromptMessage = "Host: \(challenge.request.endpoint.hostname):\(challenge.request.endpoint.port)\nAlgorithm: \(challenge.request.algorithm.rawValue)\nFingerprint: \(challenge.request.fingerprint)"
                    LogManager.info(
                        .ssh,
                        "native interaction requested stage=hostKey challenge=\(challenge.id.uuidString) algorithm=\(challenge.request.algorithm.rawValue)"
                    )
                case .credential(let challenge):
                    pendingNativeCredentialChallengeID = challenge.id
                    activeSSHAuthStage = challenge.kind == .password ? .password : .passphrase
                    isPrivateKeyPassphrasePrompt = challenge.kind == .privateKeyPassphrase
                    connectionState = challenge.kind == .password
                        ? "Waiting (password)"
                        : "Waiting (passphrase)"
                    passwordPromptMessage = activeSSHHostAddress ?? ""
                    LogManager.info(
                        .ssh,
                        "native interaction requested stage=\(challenge.kind.rawValue) challenge=\(challenge.id.uuidString)"
                    )
                case .keyboardInteractive(let challenge):
                    handleNativeKeyboardInteractiveChallenge(challenge)
                }
            }
        }
    }

    private func applyPendingResizeIfNeeded() async {
        guard !isApplyingPendingResize else { return }
        isApplyingPendingResize = true
        defer { isApplyingPendingResize = false }

        while true {
            guard let pendingSize = pendingPTYSize else { return }
            guard pendingSize != lastAppliedPTYSize else {
                pendingPTYSize = nil
                return
            }
            guard let sessionID, let manager = activeSessionManager else { return }

            do {
                try await manager.resize(sessionID: sessionID, pty: pendingSize)
                lastAppliedPTYSize = pendingSize
                if pendingPTYSize == pendingSize {
                    pendingPTYSize = nil
                }
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

        var host = config.sourceHost
            ?? RemoraCore.Host(
                name: trimmedHost,
                address: trimmedHost,
                port: config.hostPort,
                username: trimmedUser,
                auth: auth
            )

        host.address = trimmedHost
        host.port = config.hostPort
        host.username = trimmedUser
        host.auth = auth
        if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            host.name = trimmedHost
        }

        return host
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
        displayEndsAtLineStart = terminalView.isCursorAtLineStart
        pendingOutput.removeAll(keepingCapacity: false)
    }

    private func clearTranscript() {
        transcriptBuffer.removeAll(keepingCapacity: false)
        transcriptSnapshot = ""
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        outputFlushTask?.cancel()
        outputFlushTask = nil
        outputBatchBuffer.removeAll(keepingCapacity: false)
        outputBatchSessionID = nil
        pendingOutput.removeAll(keepingCapacity: false)
        promptBoundaryProcessor = TerminalPromptBoundaryProcessor()
        displayEndsAtLineStart = true
        activeSSHAuthStage = nil
        hostKeyPromptMessage = nil
        otpPromptMessage = nil
        passwordPromptMessage = nil
        keyboardInteractiveChallenge = nil
    }

    private func appendTranscript(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return }

        updateWorkingDirectory(with: chunk)

        transcriptBuffer.append(chunk)
        if transcriptBuffer.count > maxTranscriptCharacters {
            transcriptBuffer.removeFirst(transcriptBuffer.count - maxTranscriptCharacters)
        }
        if transcriptSnapshot.isEmpty {
            refreshTranscriptSnapshot()
            return
        }
        scheduleTranscriptRefresh()
    }

    private func scheduleTranscriptRefresh() {
        guard transcriptRefreshTask == nil else { return }
        transcriptRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            self.refreshTranscriptSnapshot()
            self.transcriptRefreshTask = nil
        }
    }

    private func refreshTranscriptSnapshot() {
        let sanitized = stripANSISequences(from: transcriptBuffer)
            .unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0) || $0 == "\t" || $0 == "\n" || $0 == "\r"
            }
            .map(Character.init)
        transcriptSnapshot = String(sanitized)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func updateDisplayLineState(with data: Data) {
        let sanitized = stripANSISequences(from: String(decoding: data, as: UTF8.self))
        for byte in sanitized.utf8 {
            switch byte {
            case 0x0A, 0x0D:
                displayEndsAtLineStart = true
            case 0x20...0x7E, 0xA0...0xFF:
                displayEndsAtLineStart = false
            default:
                break
            }
        }
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
        let belIndex = remainder.firstIndex(of: "\u{0007}")
        let stIndex = remainder.range(of: "\u{001B}\\")?.lowerBound
        let terminatorIndex: String.Index? = switch (belIndex, stIndex) {
        case let (bel?, st?):
            min(bel, st)
        case let (bel?, nil):
            bel
        case let (nil, st?):
            st
        case (nil, nil):
            nil
        }
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

    func handleNativeKeyboardInteractiveChallenge(
        _ challenge: KeyboardInteractiveChallenge
    ) {
        pendingNativeKeyboardChallengeID = challenge.id
        hostKeyPromptMessage = nil
        otpPromptMessage = nil
        passwordPromptMessage = nil
        isPrivateKeyPassphrasePrompt = false

        if challenge.prompts.count > 1 {
            activeSSHAuthStage = .keyboardInteractive
            connectionState = "Waiting (authentication)"
            keyboardInteractiveChallenge = challenge
        } else {
            keyboardInteractiveChallenge = nil
            let promptText = challenge.prompts.map(\.text).joined(separator: " ").lowercased()
            if promptText.contains("otp") || promptText.contains("code") || promptText.contains("token") {
                activeSSHAuthStage = .otp
                connectionState = "Waiting (otp)"
                otpPromptMessage = activeSSHHostAddress ?? ""
            } else {
                activeSSHAuthStage = .password
                connectionState = "Waiting (password)"
                passwordPromptMessage = activeSSHHostAddress ?? ""
            }
        }

        let echoCount = challenge.prompts.filter(\.echo).count
        LogManager.info(
            .ssh,
            "native interaction requested stage=keyboardInteractive challenge=\(challenge.id.uuidString) prompts=\(challenge.prompts.count) echoPrompts=\(echoCount)"
        )
    }

    private static func failureCategory(_ reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.contains("permission denied") { return "permissionDenied" }
        if normalized.contains("host identification has changed") { return "hostKeyChanged" }
        if normalized.contains("host key verification failed") { return "hostKeyVerification" }
        if normalized.contains("connection closed") { return "connectionClosed" }
        if normalized.contains("timed out") || normalized.contains("timeout") { return "timeout" }
        return "other"
    }

}
