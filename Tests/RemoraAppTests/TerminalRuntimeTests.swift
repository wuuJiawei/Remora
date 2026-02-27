import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

@MainActor
struct TerminalRuntimeTests {
    @Test
    func connectMockPublishesTranscript() async {
        let runtime = TerminalRuntime()
        runtime.connectMock()

        let hasTranscript = await waitUntil(timeout: 2.0) {
            !runtime.transcriptSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        #expect(hasTranscript, "Runtime should publish transcript output after mock connect.")
        #expect(runtime.transcriptSnapshot.contains("Connected to"))
        runtime.disconnect()
    }

    @Test
    func connectSSHUsesSSHSessionManagerPath() async {
        let mockManager = SessionManager(sshClientFactory: { MockSSHClient() })
        let sshManager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(
            mockSessionManager: mockManager,
            sshSessionManager: sshManager
        )

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)

        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }

        #expect(connected, "Runtime should connect through SSH mode when connectSSH is used.")
        #expect(runtime.transcriptSnapshot.contains("Connected to"))
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
