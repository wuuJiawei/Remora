import Foundation
import Testing
@testable import RemoraApp

private actor TransferConcurrencyProbe {
    private var inFlight = 0
    private var maxInFlight = 0

    func begin() {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func end() {
        inFlight = max(0, inFlight - 1)
    }

    func observedMax() -> Int {
        maxInFlight
    }
}

struct TransferCenterTests {
    @Test
    func respectsMaxConcurrentTransfers() async throws {
        let center = TransferCenter(maxConcurrentTransfers: 2)
        let probe = TransferConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await center.acquireSlot()
                    await probe.begin()
                    try? await Task.sleep(for: .milliseconds(30))
                    await probe.end()
                    await center.releaseSlot()
                }
            }
        }

        let maxConcurrency = await probe.observedMax()
        #expect(maxConcurrency <= 2)
    }
}
