import Foundation

public final class ScrollbackStore {
    private let segmentSize: Int
    private var segments: [[TerminalLine]] = [[]]

    public init(segmentSize: Int = 1024) {
        self.segmentSize = max(1, segmentSize)
    }

    public func append(_ line: TerminalLine) {
        if segments.isEmpty {
            segments = [[line]]
            return
        }

        if segments[segments.count - 1].count >= segmentSize {
            segments.append([line])
        } else {
            segments[segments.count - 1].append(line)
        }
    }

    public func allLines() -> [TerminalLine] {
        segments.flatMap { $0 }
    }

    public func line(at index: Int) -> TerminalLine? {
        guard index >= 0 else { return nil }
        var remaining = index
        for segment in segments {
            if remaining < segment.count {
                return segment[remaining]
            }
            remaining -= segment.count
        }
        return nil
    }

    public func lineCount() -> Int {
        segments.reduce(into: 0) { $0 += $1.count }
    }

    public func segmentCount() -> Int {
        segments.count
    }
}
