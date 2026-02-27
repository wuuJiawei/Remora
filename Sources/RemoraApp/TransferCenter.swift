import Foundation

actor TransferCenter {
    private let maxConcurrentTransfers: Int
    private var activeTransfers = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentTransfers: Int) {
        self.maxConcurrentTransfers = max(1, maxConcurrentTransfers)
    }

    func acquireSlot() async {
        if activeTransfers < maxConcurrentTransfers {
            activeTransfers += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseSlot() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
            return
        }

        activeTransfers = max(0, activeTransfers - 1)
    }
}
