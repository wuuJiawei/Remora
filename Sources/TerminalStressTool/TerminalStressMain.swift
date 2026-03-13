import Foundation
import RemoraCore
import SwiftTerm

@main
enum TerminalStressMain {
    static func main() async {
        let lines = 50_000
        let metrics = PerformanceMetrics()
        let clock = ContinuousClock()
        let delegate = NullTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 160, rows: 48)
        )

        var payload = Data()
        for idx in 0 ..< lines {
            payload.append(contentsOf: "\u{001B}[3\(idx % 8)mline-\(idx) lorem ipsum dolor sit amet\u{001B}[0m\r\n".utf8)
        }

        let start = clock.now
        terminal.feed(buffer: ArraySlice(payload))
        let duration = start.duration(to: clock.now)
        let ms = durationToMilliseconds(duration)
        let throughput = Double(payload.count) / max(ms / 1_000, 0.001)

        await metrics.record(
            PerformanceSample(
                frameDurationMS: ms,
                inputLatencyMS: 0,
                bytesPerSecond: throughput
            )
        )

        print("parsed_lines=\(lines) bytes=\(payload.count) elapsed_ms=\(String(format: "%.2f", ms)) throughput_Bps=\(String(format: "%.0f", throughput))")
        print(await metrics.summary())
    }

    private static func durationToMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
