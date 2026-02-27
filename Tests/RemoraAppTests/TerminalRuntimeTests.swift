import Foundation
import Testing
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
