import Foundation

enum TerminalFeedBackpressurePolicy {
    case keepNewest
    case keepOldest
    case unbounded
}

/// Batches high-frequency terminal output before parsing it on the main run loop.
@MainActor
final class TerminalFeedCoalescer {
    private weak var terminalView: TerminalView?
    private var pendingData = Data()
    private var timer: Timer?
    private let runLoopMode: RunLoop.Mode
    private var droppedBytesStorage: UInt64 = 0

    let flushInterval: TimeInterval
    let maxPendingBytes: Int
    let maxBytesPerFlush: Int
    let backpressurePolicy: TerminalFeedBackpressurePolicy

    var pendingByteCount: Int {
        pendingData.count
    }

    var droppedByteCount: UInt64 {
        droppedBytesStorage
    }

    init(
        terminalView: TerminalView,
        flushInterval: TimeInterval,
        maxPendingBytes: Int,
        maxBytesPerFlush: Int,
        backpressurePolicy: TerminalFeedBackpressurePolicy,
        runLoopMode: RunLoop.Mode = .default
    ) {
        self.terminalView = terminalView
        self.flushInterval = max(0.001, flushInterval)
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.maxBytesPerFlush = max(1, maxBytesPerFlush)
        self.backpressurePolicy = backpressurePolicy
        self.runLoopMode = runLoopMode

        startTimer()
    }

    func append(data: Data) {
        append(contentsOf: data)
    }

    func append(byteArray: ArraySlice<UInt8>) {
        append(contentsOf: byteArray)
    }

    func append(text: String) {
        append(contentsOf: text.utf8)
    }

    func flush() {
        let bytes = nextFlushChunk()
        guard !bytes.isEmpty else { return }
        terminalView?.feed(byteArray: bytes[...])
    }

    func flushAll() {
        while true {
            let bytes = nextFlushChunk()
            guard !bytes.isEmpty else { return }
            terminalView?.feed(byteArray: bytes[...])
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        pendingData.removeAll(keepingCapacity: false)
    }

    private func append<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
        switch backpressurePolicy {
        case .keepNewest, .unbounded:
            pendingData.append(contentsOf: bytes)
            applyBackpressureIfNeeded()
        case .keepOldest:
            let freeCapacity = maxPendingBytes - pendingData.count
            if freeCapacity <= 0 {
                droppedBytesStorage += UInt64(bytes.underestimatedCount)
                return
            }

            var appended = 0
            for byte in bytes {
                if appended >= freeCapacity {
                    droppedBytesStorage += 1
                } else {
                    pendingData.append(byte)
                    appended += 1
                }
            }
        }
    }

    private func nextFlushChunk() -> [UInt8] {
        guard !pendingData.isEmpty else { return [] }
        let byteCount = min(maxBytesPerFlush, pendingData.count)
        let chunk = Array(pendingData.prefix(byteCount))
        pendingData.removeFirst(byteCount)
        return chunk
    }

    private func applyBackpressureIfNeeded() {
        guard backpressurePolicy != .unbounded,
              pendingData.count > maxPendingBytes
        else { return }

        let overflow = pendingData.count - maxPendingBytes
        switch backpressurePolicy {
        case .keepNewest:
            pendingData.removeFirst(overflow)
            droppedBytesStorage += UInt64(overflow)
        case .keepOldest:
            pendingData.removeLast(overflow)
            droppedBytesStorage += UInt64(overflow)
        case .unbounded:
            break
        }
    }

    private func startTimer() {
        guard timer == nil else { return }

        let newTimer = Timer(timeInterval: flushInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.flush()
            }
        }
        RunLoop.main.add(newTimer, forMode: runLoopMode)
        timer = newTimer
    }
}

extension TerminalView {
    func makeFeedCoalescer(
        flushInterval: TimeInterval,
        maxPendingBytes: Int,
        maxBytesPerFlush: Int,
        backpressurePolicy: TerminalFeedBackpressurePolicy,
        runLoopMode: RunLoop.Mode = .default
    ) -> TerminalFeedCoalescer {
        TerminalFeedCoalescer(
            terminalView: self,
            flushInterval: flushInterval,
            maxPendingBytes: maxPendingBytes,
            maxBytesPerFlush: maxBytesPerFlush,
            backpressurePolicy: backpressurePolicy,
            runLoopMode: runLoopMode
        )
    }
}
