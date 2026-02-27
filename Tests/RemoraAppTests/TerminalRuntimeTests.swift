import Foundation
import Testing
import RemoraCore
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
        }

        #expect(connected, "Runtime should connect through SSH mode when connectSSH is used.")
        #expect(runtime.transcriptSnapshot.contains("Connected to"))
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
}
