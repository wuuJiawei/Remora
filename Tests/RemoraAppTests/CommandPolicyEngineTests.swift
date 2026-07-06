import Testing
@testable import RemoraApp

struct CommandPolicyEngineTests {
    private let engine = CommandPolicyEngine()

    @Test
    func safeCommandIsClassifiedAsSafe() {
        let result = engine.evaluate(command: "df -h", mode: .review)

        #expect(result.risk == .safe)
        #expect(result.decision == .requireConfirmation)
    }

    @Test
    func sudoCommandRequiresConfirmation() {
        let result = engine.evaluate(command: "sudo systemctl status nginx", mode: .intervention)

        #expect(result.risk == .review)
        #expect(result.decision == .requireConfirmation)
    }

    @Test
    func rmRfRootIsDenied() {
        let result = engine.evaluate(command: "rm -rf /", mode: .intervention)

        #expect(result.risk == .danger)
        #expect(result.decision == .deny)
    }

    @Test
    func dockerLogsWithTailIsSafeDiagnostic() {
        let result = engine.evaluate(command: "docker logs --tail 100 nginx", mode: .intervention)

        #expect(result.risk == .safe)
        #expect(result.decision == .allowAutoRun)
    }

    @Test
    func systemctlRestartRequiresConfirmation() {
        let result = engine.evaluate(command: "systemctl restart nginx", mode: .intervention)

        #expect(result.risk == .review)
        #expect(result.decision == .requireConfirmation)
    }

    @Test
    func interventionModeAllowsAutoRunOnlyForSafeDiagnostics() {
        let safe = engine.evaluate(command: "uptime", mode: .intervention)
        let review = engine.evaluate(command: "docker compose down", mode: .intervention)

        #expect(safe.risk == .safe)
        #expect(safe.decision == .allowAutoRun)
        #expect(review.risk == .review)
        #expect(review.decision == .requireConfirmation)
    }

    @Test
    func suggestAndReviewModesNeverAutoRun() {
        let suggest = engine.evaluate(command: "whoami", mode: .suggest)
        let review = engine.evaluate(command: "whoami", mode: .review)

        #expect(suggest.risk == .safe)
        #expect(suggest.decision == .requireConfirmation)
        #expect(review.risk == .safe)
        #expect(review.decision == .requireConfirmation)
    }
}
