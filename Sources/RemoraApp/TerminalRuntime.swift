import Foundation
import RemoraCore
import RemoraTerminal

enum ConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case ssh = "SSH"

    var id: String { rawValue }
}

struct TerminalConnectConfig: Sendable {
    var hostAddress: String
    var hostPort: Int
    var username: String
    var privateKeyPath: String?
}

@MainActor
final class TerminalRuntime: ObservableObject {
    @Published var connectionState: String = "Idle"
    @Published var transcriptSnapshot: String = ""

    private let sessionManager: SessionManager

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

    init(
        sessionManager: SessionManager = SessionManager(sshClientFactory: { OpenSSHProcessClient() })
    ) {
        self.sessionManager = sessionManager
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

    func connectLocalSSH() {
        connect(
            using: TerminalConnectConfig(
                hostAddress: "127.0.0.1",
                hostPort: 22,
                username: NSUserName(),
                privateKeyPath: nil
            )
        )
    }

    func connectSSH(address: String, port: Int, username: String, privateKeyPath: String?) {
        connect(
            using: TerminalConnectConfig(
                hostAddress: address,
                hostPort: port,
                username: username,
                privateKeyPath: privateKeyPath
            )
        )
    }

    func connect(using config: TerminalConnectConfig) {
        guard sessionID == nil else { return }
        connectionState = "Connecting"
        clearTranscript()
        clearInputQueue()

        guard let host = buildHostConfiguration(config: config) else {
            connectionState = "配置错误：请检查主机、端口、用户名"
            return
        }

        activeSessionManager = sessionManager

        Task {
            do {
                let descriptor = try await sessionManager.startSession(
                    for: host,
                    pty: .init(columns: 120, rows: 30)
                )
                sessionID = descriptor.id
                connectionState = "Connected (SSH)"
                bindOutput(for: descriptor.id, manager: sessionManager)
                bindSessionState(for: descriptor.id, manager: sessionManager)
            } catch {
                connectionState = "Failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        guard let sessionID, let manager = activeSessionManager else { return }

        Task {
            await manager.stopSession(id: sessionID)
            await MainActor.run {
                self.sessionID = nil
                self.activeSessionManager = nil
                self.connectionState = "Disconnected"
                self.streamTask?.cancel()
                self.streamTask = nil
                self.stateTask?.cancel()
                self.stateTask = nil
                self.pendingOutput.removeAll(keepingCapacity: false)
                self.clearInputQueue()
            }
        }
    }

    private func bindOutput(for id: UUID, manager: SessionManager) {
        streamTask?.cancel()
        streamTask = Task {
            let stream = await manager.sessionOutputStream(sessionID: id)
            for await data in stream {
                await MainActor.run {
                    appendTranscript(data)
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
                        connectionState = "Connected (SSH)"
                    case .stopped:
                        connectionState = "Disconnected"
                    case .failed(let reason):
                        connectionState = "Failed: \(reason)"
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

    private func buildHostConfiguration(config: TerminalConnectConfig) -> RemoraCore.Host? {
        let trimmedHost = config.hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else { return nil }
        guard config.hostPort > 0, config.hostPort < 65536 else { return nil }

        let keyPath = config.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: HostAuth = {
            if let keyPath, !keyPath.isEmpty {
                return HostAuth(method: .privateKey, keyReference: keyPath)
            }
            return HostAuth(method: .agent)
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
}
