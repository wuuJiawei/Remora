import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

@MainActor
struct TerminalRuntimeTests {
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
