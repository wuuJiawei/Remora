import Foundation
import Testing
import RemoraCore
import RemoraTerminal
@testable import RemoraApp

@MainActor
struct TerminalRuntimeTests {
    @Test
    func detectsSSHAuthenticationStagesFromPromptText() {
        let hostKeyPrompt = "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        let passwordPrompt = "deploy@example.com's password:"
        let otpPrompt = "Verification code:"
        let passphrasePrompt = "Enter passphrase for key '/Users/demo/.ssh/id_ed25519':"

        #expect(TerminalRuntime.detectSSHAuthStage(in: hostKeyPrompt.lowercased()) == .hostKey)
        #expect(TerminalRuntime.detectSSHAuthStage(in: passwordPrompt.lowercased()) == .password)
        #expect(TerminalRuntime.detectSSHAuthStage(in: otpPrompt.lowercased()) == .otp)
        #expect(TerminalRuntime.detectSSHAuthStage(in: passphrasePrompt.lowercased()) == .passphrase)
    }

    @Test
    func hostKeyPromptMessageIncludesHostAndRelevantLines() {
        let prompt = """
        The authenticity of host '192.168.30.120 (192.168.30.120)' can't be established.
        ED25519 key fingerprint is SHA256:example.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """

        let message = TerminalRuntime.makeHostKeyPromptMessage(
            from: prompt,
            hostAddress: "192.168.30.120"
        )

        #expect(message.contains("Host: 192.168.30.120"))
        #expect(message.contains("authenticity of host"))
        #expect(message.contains("yes/no"))
    }

    @Test
    func connectLocalShellPublishesTranscript() async {
        let localManager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(
            localSessionManager: localManager,
            sshSessionManager: SessionManager(sshClientFactory: { MockSSHClient() })
        )
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
        let localManager = SessionManager(sshClientFactory: { MockSSHClient() })
        let sshManager = SessionManager(sshClientFactory: { MockSSHClient() })
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
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
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
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
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
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
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
    func connectDisconnectAndReconnectLifecycle() async {
        let localManager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(
            localSessionManager: localManager,
            sshSessionManager: SessionManager(sshClientFactory: { MockSSHClient() })
        )

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
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
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
    func workingDirectoryTrackingFallsBackToPwdProbe() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/srv/app")
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.setWorkingDirectoryTrackingEnabled(true)
        runtime.connectLocalShell()

        let initialDetected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/srv/app"
        }
        #expect(initialDetected, "Tracking should discover the current directory from pwd output.")
        guard initialDetected else { return }

        await recorder.reset()
        runtime.changeDirectory(to: "/srv/app/logs")

        let movedDetected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/srv/app/logs"
        }
        #expect(movedDetected, "Working directory should converge to the moved path.")

        let probeIssued = await waitUntilAsync(timeout: 2.0) {
            await recorder.commands.contains("pwd")
        }
        #expect(probeIssued, "Runtime should issue a pwd fallback probe after cd.")
        runtime.disconnect()
    }

    @Test
    func workingDirectoryProbeHandlesAnsiWrappedPwdOutput() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(
                    recorder: recorder,
                    initialDirectory: "/var/www/app",
                    pwdOutputStyle: .ansiWrapped
                )
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.setWorkingDirectoryTrackingEnabled(true)
        runtime.connectLocalShell()

        let detected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/var/www/app"
        }
        #expect(detected, "ANSI-wrapped pwd output should still update workingDirectory.")
        runtime.disconnect()
    }

    @Test
    func repeatedSameResizeOnlyAppliesOnce() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/")
            }
        )
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
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/")
            }
        )
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
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
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
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
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
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/")
            }
        )
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
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/")
            }
        )
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
    func runAssistantCommandSendsCtrlCBeforeExecutingCommand() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/")
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        await recorder.reset()
        runtime.runAssistantCommand("pwd")

        let wroteCtrlCFirst = await waitUntilAsync(timeout: 2.0) {
            let writes = await recorder.rawWrites
            guard let first = writes.first else { return false }
            return first.contains("\u{03}")
        }
        #expect(wroteCtrlCFirst, "Assistant run should send Ctrl+C before writing the command.")
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
