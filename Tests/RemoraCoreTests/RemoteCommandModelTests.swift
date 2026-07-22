import Foundation
import Testing
@testable import RemoraCore

@Suite("Remote command models")
struct RemoteCommandModelTests {
    @Test("Commands default to no replay")
    func commandsDefaultToNoReplay() {
        let request = RemoteCommandRequest(executable: .path("/usr/bin/true"))
        #expect(request.replayPolicy == .never)
        #expect(!request.replayPolicy.permitsAutomaticRetry(hasProducedOutput: false))
    }

    @Test("Read-only commands stop being retryable after output")
    func readOnlyRetryStopsAfterOutput() {
        let policy = CommandReplayPolicy.readOnly
        #expect(policy.permitsAutomaticRetry(hasProducedOutput: false))
        #expect(!policy.permitsAutomaticRetry(hasProducedOutput: true))
    }

    @Test("Idempotent operations require an explicit key")
    func idempotentOperationsCarryKey() {
        let policy = CommandReplayPolicy.idempotent(operationKey: "operation-123")
        #expect(policy == .idempotent(operationKey: "operation-123"))
        #expect(policy.permitsAutomaticRetry(hasProducedOutput: false))
        #expect(!CommandReplayPolicy.idempotent(operationKey: "")
            .permitsAutomaticRetry(hasProducedOutput: false))
    }
}
