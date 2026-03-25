import SwiftUI
import Testing
@testable import RemoraApp

@Suite(.serialized)
@MainActor
struct ServerMetricsPanelTests {
    @Test
    func rendersInLightAndDarkAppearances() {
        assertPanelRendering(for: .light)
        assertPanelRendering(for: .dark)
    }

    private func assertPanelRendering(for colorScheme: ColorScheme) {
        let previous = ServerResourceMetricsSnapshot(
            cpuFraction: 0.24,
            memoryFraction: 0.56,
            swapFraction: 0.08,
            diskFraction: 0.31,
            memoryUsedBytes: 2_147_483_648,
            memoryTotalBytes: 4_294_967_296,
            swapUsedBytes: 268_435_456,
            swapTotalBytes: 2_147_483_648,
            diskUsedBytes: 12_884_901_888,
            diskTotalBytes: 34_359_738_368,
            processCount: 212,
            networkRXBytes: 10_000_000,
            networkTXBytes: 4_000_000,
            diskReadBytes: 1_000_000,
            diskWriteBytes: 2_000_000,
            loadAverage1: 0.34,
            loadAverage5: 0.27,
            loadAverage15: 0.19,
            uptimeSeconds: 86_400,
            topProcesses: [
                ServerTopProcessMetric(memoryBytes: 1_887_436_800, cpuPercent: 3.3, command: "java")
            ],
            filesystems: [
                ServerFilesystemMetric(mountPath: "/", availableBytes: 4_724_637_696, totalBytes: 24_980_656_128)
            ],
            sampledAt: Date(timeIntervalSince1970: 100)
        )
        let current = ServerResourceMetricsSnapshot(
            cpuFraction: 0.32,
            memoryFraction: 0.58,
            swapFraction: 0.1,
            diskFraction: 0.33,
            memoryUsedBytes: 2_362_232_012,
            memoryTotalBytes: 4_294_967_296,
            swapUsedBytes: 322_122_547,
            swapTotalBytes: 2_147_483_648,
            diskUsedBytes: 13_099_650_252,
            diskTotalBytes: 34_359_738_368,
            processCount: 218,
            networkRXBytes: 10_500_000,
            networkTXBytes: 4_450_000,
            diskReadBytes: 1_120_000,
            diskWriteBytes: 2_150_000,
            loadAverage1: 0.41,
            loadAverage5: 0.31,
            loadAverage15: 0.22,
            uptimeSeconds: 86_430,
            topProcesses: [
                ServerTopProcessMetric(memoryBytes: 1_887_436_800, cpuPercent: 3.3, command: "java"),
                ServerTopProcessMetric(memoryBytes: 119_537_664, cpuPercent: 1.7, command: "mysqld")
            ],
            filesystems: [
                ServerFilesystemMetric(mountPath: "/", availableBytes: 4_724_637_696, totalBytes: 24_980_656_128),
                ServerFilesystemMetric(mountPath: "/dev/shm", availableBytes: 2_038_063_104, totalBytes: 2_038_063_104)
            ],
            sampledAt: Date(timeIntervalSince1970: 103)
        )
        let state = ServerHostMetricsState(
            snapshot: current,
            previousSnapshot: previous,
            isLoading: false,
            errorMessage: nil,
            lastAttemptAt: current.sampledAt
        )

        let renderer = ImageRenderer(
            content: ServerMetricsPanel(
                hostTitle: "root@192.0.2.10:22",
                connectionState: "Connected",
                state: state
            )
            .environment(\.colorScheme, colorScheme)
        )
        renderer.proposedSize = .init(width: 320, height: 720)
        renderer.scale = 1

        let image = renderer.nsImage
        #expect(image != nil, "Panel should render in \(String(describing: colorScheme)) mode.")
        #expect(image?.size.width ?? 0 >= 260, "Rendered panel should keep a readable width in \(String(describing: colorScheme)) mode.")
        #expect(image?.size.height ?? 0 >= 300, "Rendered panel should keep a readable height in \(String(describing: colorScheme)) mode.")
    }
}
