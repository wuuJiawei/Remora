import AppKit
import Foundation
import Testing
import RemoraCore
import RemoraTerminal
@testable import RemoraApp

@Suite(.serialized)
@MainActor
struct TerminalRuntimeTests {
    @Test
    func connectLocalShellPublishesTranscript() async {
        let localManager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: localManager, sshSessionManager: makeMockSessionManager())
        runtime.connectLocalShell()

        let hasTranscript = await waitUntil(timeout: 2.0) {
            !runtime.transcriptSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        #expect(hasTranscript, "Runtime should publish transcript output after local shell connect.")
        #expect(runtime.transcriptSnapshot.contains("Connected to"))
        runtime.disconnect()
    }

    @Test
    func connectSSHUsesSSHSessionManagerPath() async {
        let localManager = makeMockSessionManager()
        let sshManager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: localManager, sshSessionManager: sshManager)

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
                && runtime.transcriptSnapshot.contains("Connected to")
        }

        #expect(
            connected,
            "Runtime should connect through SSH mode and publish transcript output when connectSSH is used."
        )
        #expect(runtime.connectedSSHHost?.address == "127.0.0.1")
        runtime.disconnect()
    }

    @Test
    func connectSSHHostPreservesOriginalHostIdentity() async {
        let manager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
        let host = Host(
            name: "prod-api",
            address: "47.100.100.215",
            username: "root",
            group: "Production",
            auth: HostAuth(method: .agent),
            quickCommands: [
                HostQuickCommand(name: "Deploy", command: "cd /srv/app && ./deploy.sh")
            ]
        )

        runtime.connectSSH(host: host)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)") && runtime.connectedSSHHost != nil
        }
        #expect(connected)
        guard connected else { return }

        #expect(runtime.connectedSSHHost?.id == host.id)
        #expect(runtime.connectedSSHHost?.name == host.name)
        #expect(runtime.connectedSSHHost?.quickCommands.count == host.quickCommands.count)
        runtime.disconnect()
    }

    @Test
    func disconnectClearsConnectedSSHHost() async {
        let manager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)") && runtime.connectedSSHHost != nil
        }
        #expect(connected)
        guard connected else { return }

        runtime.disconnect()
        let disconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState == "Disconnected" && runtime.connectedSSHHost == nil
        }
        #expect(disconnected)
    }

    @Test
    func reconnectSSHSessionRestoresConnectionAfterDisconnect() async {
        let manager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let firstConnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)") && runtime.connectedSSHHost?.address == "127.0.0.1"
        }
        #expect(firstConnected)
        guard firstConnected else { return }

        runtime.disconnect()
        let disconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState == "Disconnected" && runtime.connectedSSHHost == nil
        }
        #expect(disconnected)
        guard disconnected else { return }
        #expect(runtime.reconnectableSSHHost?.address == "127.0.0.1")

        runtime.reconnectSSHSession()
        let reconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)") && runtime.connectedSSHHost?.address == "127.0.0.1"
        }
        #expect(reconnected, "Runtime should reconnect SSH with the last successful host.")
        runtime.disconnect()
    }

    @Test
    func terminalInputReconnectsSSHAfterRemoteStop() async {
        let factory = AutoStoppingShellFactory(state: .stopped, delay: .milliseconds(80))
        let manager = SessionManager(localShellFactory: factory.makeShell)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
        let view = TerminalView(rows: 4, columns: 80)
        runtime.attach(view: view)

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let disconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState == "Disconnected"
                && runtime.connectedSSHHost == nil
                && runtime.reconnectableSSHHost?.address == "127.0.0.1"
        }
        #expect(disconnected)
        guard disconnected else { return }

        view.send(source: view, data: ArraySlice(Data("\r".utf8)))

        let reconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
                && runtime.connectedSSHHost?.address == "127.0.0.1"
                && factory.sessionCount >= 2
        }
        #expect(reconnected, "Pressing Enter in a remotely disconnected terminal should reconnect the SSH session.")
        runtime.disconnect()
    }

    @Test
    func terminalInputReconnectsSSHAfterRemoteFailure() async {
        let factory = AutoStoppingShellFactory(state: .failed("timed out"), delay: .milliseconds(80))
        let manager = SessionManager(localShellFactory: factory.makeShell)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
        let view = TerminalView(rows: 4, columns: 80)
        runtime.attach(view: view)

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let failed = await waitUntil(timeout: 2.0) {
            runtime.connectionState == "Failed: timed out"
                && runtime.connectedSSHHost == nil
                && runtime.reconnectableSSHHost?.address == "127.0.0.1"
        }
        #expect(failed)
        guard failed else { return }

        view.send(source: view, data: ArraySlice(Data("x".utf8)))

        let reconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
                && runtime.connectedSSHHost?.address == "127.0.0.1"
                && factory.sessionCount >= 2
        }
        #expect(reconnected, "Any terminal key after a failed SSH session should reconnect the last host.")
        runtime.disconnect()
    }

    @Test
    func terminalInputDoesNotReconnectAfterManualDisconnect() async {
        let factory = AutoStoppingShellFactory(state: .stopped, delay: nil)
        let manager = SessionManager(localShellFactory: factory.makeShell)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
        let view = TerminalView(rows: 4, columns: 80)
        runtime.attach(view: view)

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
                && runtime.connectedSSHHost?.address == "127.0.0.1"
        }
        #expect(connected)
        guard connected else { return }

        runtime.disconnect()
        let disconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState == "Disconnected" && runtime.connectedSSHHost == nil
        }
        #expect(disconnected)
        guard disconnected else { return }

        view.send(source: view, data: ArraySlice(Data("\r".utf8)))
        try? await Task.sleep(for: .milliseconds(200))

        #expect(factory.sessionCount == 1, "Manual disconnect should remain explicit; terminal input must not reconnect it.")
        #expect(runtime.connectionState == "Disconnected")
    }

    @Test
    func connectDisconnectAndReconnectLifecycle() async {
        let localManager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: localManager, sshSessionManager: makeMockSessionManager())

        runtime.connectLocalShell()
        let firstConnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(firstConnected, "First connection should succeed.")

        runtime.disconnect()
        let disconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState == "Disconnected"
        }
        #expect(disconnected, "Disconnect should update runtime state.")

        runtime.connectLocalShell()
        let reconnected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected") && runtime.transcriptSnapshot.contains("Connected to")
        }
        #expect(reconnected, "Runtime should reconnect and resume transcript publishing.")

        runtime.disconnect()
    }

    @Test
    func changeDirectoryUpdatesWorkingDirectoryImmediately() async {
        let manager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
                && runtime.transcriptSnapshot.contains("% ")
        }
        #expect(connected)
        guard connected else { return }

        runtime.changeDirectory(to: "/tmp")

        let updated = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/tmp"
        }
        #expect(updated, "changeDirectory should update runtime workingDirectory.")
        runtime.disconnect()
    }

    @Test
    func workingDirectoryTrackingDoesNotProbeImmediatelyOnConnect() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(
                    recorder: recorder,
                    initialDirectory: "/srv/app",
                    workingDirectoryEventStyle: .osc7OnPrompt
            )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.setWorkingDirectoryTrackingEnabled(true)
        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        let initialDetected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/srv/app"
        }
        #expect(initialDetected, "Shell integration should publish the initial SSH working directory.")

        try? await Task.sleep(nanoseconds: 450_000_000)
        let automaticPwdIssued = await recorder.commands.contains("pwd")
        #expect(automaticPwdIssued == false, "Tracking should not inject pwd immediately on SSH connect.")
        runtime.disconnect()
    }

    @Test
    func workingDirectoryTrackingDoesNotProbeAfterArbitraryCommandSubmission() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(
                    recorder: recorder,
                    initialDirectory: "/srv/app",
                    workingDirectoryEventStyle: .osc7OnPrompt
            )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.setWorkingDirectoryTrackingEnabled(true)
        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        try? await Task.sleep(nanoseconds: 450_000_000)
        await recorder.reset()

        runtime.sendText("whoami\n")

        let executed = await waitUntilAsync(timeout: 2.0) {
            await recorder.commands.contains("whoami")
        }
        #expect(executed, "Typed command should execute normally.")
        guard executed else { return }

        try? await Task.sleep(nanoseconds: 450_000_000)
        let unexpectedPwdIssued = await recorder.commands.contains("pwd")
        #expect(unexpectedPwdIssued == false, "Tracking should not inject pwd after arbitrary commands.")
        runtime.disconnect()
    }

    @Test
    func workingDirectoryTrackingFollowsTypedDirectoryChangesViaShellIntegration() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(
                    recorder: recorder,
                    initialDirectory: "/srv/app",
                    workingDirectoryEventStyle: .osc7OnPrompt
            )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.setWorkingDirectoryTrackingEnabled(true)
        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        let initialDetected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/srv/app"
        }
        #expect(initialDetected)
        guard initialDetected else { return }

        await recorder.reset()

        runtime.sendText("cd '/srv/app/logs'\n")

        let movedDetected = await waitUntil(timeout: 3.5) {
            runtime.workingDirectory == "/srv/app/logs"
        }
        #expect(movedDetected, "Shell integration should update working directory after typed cd.")

        let typedCdExecuted = await waitUntilAsync(timeout: 2.0) {
            await recorder.commands.contains("cd '/srv/app/logs'")
        }
        #expect(typedCdExecuted)

        let probeIssued = await recorder.commands.contains("pwd")
        #expect(probeIssued == false, "Shell integration should replace pwd fallback after typed cd.")
        runtime.disconnect()
    }

    @Test
    func workingDirectoryTrackingHandlesOSC7DirectoryEvents() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(
                    recorder: recorder,
                    initialDirectory: "/var/www/app",
                    pwdOutputStyle: .ansiWrapped,
                    workingDirectoryEventStyle: .osc7OnPrompt
            )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.setWorkingDirectoryTrackingEnabled(true)
        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        let initialDetected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/var/www/app"
        }
        #expect(initialDetected)
        guard initialDetected else { return }

        await recorder.reset()
        runtime.sendText("cd '/var/www/app/releases'\n")

        let detected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/var/www/app/releases"
        }
        #expect(detected, "OSC 7 directory events should update workingDirectory without pwd probes.")

        let probeIssued = await recorder.commands.contains("pwd")
        #expect(probeIssued == false, "OSC 7 tracking should not need pwd fallback.")
        runtime.disconnect()
    }

    @Test
    func workingDirectoryTrackingHandlesSTTerminatedOSC7BeforePromptNoise() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(
                    recorder: recorder,
                    initialDirectory: "/root",
                    workingDirectoryEventStyle: .osc7WithSTTerminatorAndPromptNoise
            )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "root", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        let detected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/root"
        }
        #expect(detected, "ST-terminated OSC 7 should stop before later title/prompt escape sequences.")
        #expect(runtime.workingDirectory?.contains("\u{001B}") == false)
        runtime.disconnect()
    }

    @Test
    func repeatedSameResizeOnlyAppliesOnce() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(recorder: recorder)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        await recorder.reset()
        for _ in 0..<12 {
            runtime.resize(columns: 96, rows: 15)
        }

        let resized = await waitUntilAsync(timeout: 2.0) {
            await recorder.resizeRequests.contains(where: { $0.columns == 96 && $0.rows == 15 })
        }
        #expect(resized, "Runtime should apply queued resize.")

        try? await Task.sleep(nanoseconds: 200_000_000)
        let matchingCount = await recorder.resizeRequests.filter { $0.columns == 96 && $0.rows == 15 }.count
        #expect(matchingCount == 1, "Repeated same-size resize calls should be coalesced into one apply.")
        runtime.disconnect()
    }

    @Test
    func rapidDifferentResizesAreDebouncedToLatestSize() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(recorder: recorder)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        await recorder.reset()
        runtime.resize(columns: 96, rows: 21)
        runtime.resize(columns: 96, rows: 27)
        runtime.resize(columns: 96, rows: 32)
        runtime.resize(columns: 96, rows: 33)

        let applied = await waitUntilAsync(timeout: 2.0) {
            await recorder.resizeRequests.contains(where: { $0.columns == 96 && $0.rows == 33 })
        }
        #expect(applied, "Latest resize should be applied after debounce.")

        try? await Task.sleep(nanoseconds: 250_000_000)
        let requests = await recorder.resizeRequests
        #expect(requests.count == 1, "Rapid resize bursts should be coalesced into one apply.")
        if let only = requests.first {
            #expect(only.columns == 96 && only.rows == 33, "Coalesced resize should use the latest size.")
        }
        runtime.disconnect()
    }

    @Test
    func transcriptSnapshotStripsANSIEditingSequences() async {
        let manager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
                && runtime.transcriptSnapshot.contains("% ")
        }
        #expect(connected)
        guard connected else { return }

        runtime.sendText("whoami")
        let typed = await waitUntil(timeout: 2.0) {
            runtime.transcriptSnapshot.contains("whoami")
        }
        #expect(typed)
        guard typed else { return }

        let baselineSnapshot = runtime.transcriptSnapshot
        runtime.sendLeftArrow(count: 2)
        runtime.sendText("X")
        let updated = await waitUntil(timeout: 2.0) {
            runtime.transcriptSnapshot != baselineSnapshot
                && runtime.transcriptSnapshot.contains("X")
        }
        #expect(updated)
        guard updated else { return }

        #expect(
            !runtime.transcriptSnapshot.contains("\u{1B}"),
            "Transcript snapshot should not expose raw ANSI editing sequences."
        )
        runtime.disconnect()
    }

    @Test
    func typedEchoReachesTerminalViewWithoutFrameScaleDelay() async {
        let manager = makeMockSessionManager()
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
        let view = TerminalView(rows: 4, columns: 40)
        view.setFrameSize(NSSize(width: 480, height: 120))
        runtime.attach(view: view)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
                && view.getTerminal().buffer.x > 0
        }
        #expect(connected)
        guard connected else { return }

        let baselineColumn = view.getTerminal().buffer.x
        let clock = ContinuousClock()
        let start = clock.now
        runtime.sendText("x")

        let echoed = await waitUntilFast(timeout: 0.1) {
            view.getTerminal().buffer.x > baselineColumn
        }
        let elapsed = start.duration(to: clock.now)
        let elapsedMS = milliseconds(elapsed)

        #expect(echoed)
        #expect(elapsedMS < 20, "Terminal echo took \(elapsedMS)ms, which feels laggy for prompt editing.")
        runtime.disconnect()
    }

    @Test
    func insertAssistantCommandReplacesInputWithoutExecuting() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(recorder: recorder)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        await recorder.reset()
        runtime.insertAssistantCommand("ls -lah")

        let inserted = await waitUntilAsync(timeout: 2.0) {
            await recorder.rawWrites.joined().contains("ls -lah")
        }
        #expect(inserted, "Assistant insertion should write command text into the terminal input buffer.")
        #expect(await recorder.commands.isEmpty, "Inserted assistant command should not execute immediately.")
        runtime.disconnect()
    }

    @Test
    func runAssistantCommandExecutesImmediately() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(recorder: recorder)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        await recorder.reset()
        runtime.runAssistantCommand("pwd")

        let executed = await waitUntilAsync(timeout: 2.0) {
            await recorder.commands.contains("pwd")
        }
        #expect(executed, "Running an assistant command should send the command through the terminal session.")
        runtime.disconnect()
    }

    @Test
    func clearScreenExecutesClearCommandThroughRuntimePath() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(recorder: recorder)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        await recorder.reset()
        runtime.clearScreen()

        let cleared = await waitUntilAsync(timeout: 2.0) {
            await recorder.commands.contains("clear")
        }
        #expect(cleared, "Clear screen should send a real clear command through the runtime input path.")
        runtime.disconnect()
    }

    @Test
    func zmodemActiveSessionBlocksUserInputWrites() async {
        let recorder = TerminalCommandRecorder()
        let manager = makeRecordingSessionManager(recorder: recorder)
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        await recorder.reset()
        runtime.zmodemCoordinator.isActive = true
        runtime.sendText("ls -lah\n")
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(await recorder.rawWrites.isEmpty, "User input should be blocked while ZMODEM transfer is active.")

        runtime.zmodemCoordinator.isActive = false
        runtime.sendText("pwd\n")
        let resumed = await waitUntilAsync(timeout: 2.0) {
            await recorder.rawWrites.joined().contains("pwd")
        }
        #expect(resumed, "User input should resume once ZMODEM transfer is inactive.")
        runtime.disconnect()
    }

    @Test
    func zmodemFinishedChunkStillDeliversTrailingPromptOutput() async {
        let manager = SessionManager(localShellFactory: { _, _ in PromptAfterZmodemShellSession() })
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
        let view = TerminalView(rows: 8, columns: 80)
        runtime.attach(view: view)

        runtime.connectLocalShell()

        let rendered = await waitUntil(timeout: 2.0) {
            view.selectAll()
            NSPasteboard.general.clearContents()
            view.performTerminalAction(.copy)
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            return copied.contains("PROMPT> ") || runtime.transcriptSnapshot.contains("PROMPT> ")
        }
        #expect(rendered, "Trailing shell output after ZMODEM completion should still reach the terminal view.")
        runtime.disconnect()
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func waitUntilAsync(timeout: TimeInterval, condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    private func waitUntilFast(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
private final class AutoStoppingShellFactory: @unchecked Sendable {
    private let state: ShellSessionState
    private let delay: Duration?
    private let lock = NSLock()
    private var storedSessionCount = 0

    var sessionCount: Int {
        lock.withLock { storedSessionCount }
    }

    init(state: ShellSessionState, delay: Duration?) {
        self.state = state
        self.delay = delay
    }

    func makeShell(host: RemoraCore.Host, pty: PTYSize) async throws -> any ShellSessionProtocol {
        _ = pty
        lock.withLock {
            storedSessionCount += 1
        }
        return AutoStoppingShellSession(host: host, state: state, delay: delay)
    }
}

private final class AutoStoppingShellSession: ShellSessionProtocol, @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    private let host: RemoraCore.Host
    private let state: ShellSessionState
    private let delay: Duration?
    private var isRunning = false
    private var stopTask: Task<Void, Never>?

    init(host: RemoraCore.Host, state: ShellSessionState, delay: Duration?) {
        self.host = host
        self.state = state
        self.delay = delay
    }

    func start() async throws {
        isRunning = true
        onStateChange?(.running)
        onOutput?(Data("Connected to \(host.username)@\(host.address):\(host.port)\r\n".utf8))
        guard let delay else { return }
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.isRunning = false
            self.onStateChange?(self.state)
        }
    }

    func write(_ data: Data) async throws {
        guard isRunning else {
            throw SSHError.notConnected
        }
    }

    func resize(_ size: PTYSize) async throws {}

    func stop() async {
        stopTask?.cancel()
        stopTask = nil
        isRunning = false
        onStateChange?(.stopped)
    }
}

private final class PromptAfterZmodemShellSession: ShellSessionProtocol, @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    func start() async throws {
        onStateChange?(.running)
        onOutput?(Data("PROMPT> ".utf8))
    }

    func write(_ data: Data) async throws {}

    func resize(_ size: PTYSize) async throws {}

    func stop() async {
        onStateChange?(.stopped)
    }
}
