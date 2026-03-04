import Darwin
import Testing
@testable import RemoraCore

struct LocalShellClientTests {
    @Test
    func interruptTargetsPreferForegroundProcessGroupAndFallbackToShell() {
        let targets = LocalShellSession.interruptSignalTargets(
            foregroundProcessGroup: 2345,
            shellProcessID: 3456,
            shellProcessGroup: 2345,
            appProcessGroup: 1234
        )

        #expect(
            targets == [
                .processGroup(2345),
                .process(3456),
            ]
        )
    }

    @Test
    func interruptTargetsAvoidApplicationProcessGroup() {
        let targets = LocalShellSession.interruptSignalTargets(
            foregroundProcessGroup: 1234,
            shellProcessID: 3456,
            shellProcessGroup: 1234,
            appProcessGroup: 1234
        )

        #expect(targets == [.process(3456)])
    }

    @Test
    func interruptTargetsCanUseShellProcessGroupWhenForegroundIsMissing() {
        let targets = LocalShellSession.interruptSignalTargets(
            foregroundProcessGroup: nil,
            shellProcessID: 4567,
            shellProcessGroup: 5678,
            appProcessGroup: 1234
        )

        #expect(
            targets == [
                .processGroup(5678),
                .process(4567),
            ]
        )
    }
}
