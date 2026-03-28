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

    @Test
    func headerCardExtendsToDashboardWidth() {
        let image = renderCachedPanelImage(colorScheme: .light)
        let samples = [640, 620, 600, 580, 560, 540].map { y in
            sampleColor(in: image, x: 430, y: y)
        }
        #expect(samples.contains { color in
            guard let color else { return false }
            return color.alphaComponent > 0.01
        })
    }

    private func assertPanelRendering(for colorScheme: ColorScheme) {
        let image = renderPanelImage(colorScheme: colorScheme)
        #expect(image != nil, "Panel should render in \(String(describing: colorScheme)) mode.")
        #expect(image?.size.width ?? 0 >= 420, "Rendered panel should keep a readable dashboard width in \(String(describing: colorScheme)) mode.")
        #expect(image?.size.height ?? 0 >= 300, "Rendered panel should keep a readable height in \(String(describing: colorScheme)) mode.")
    }

    private func renderPanelImage(colorScheme: ColorScheme) -> NSImage? {
        let renderer = ImageRenderer(
            content: makePanel()
                .environment(\.colorScheme, colorScheme)
        )
        renderer.proposedSize = .init(width: 472, height: 720)
        renderer.scale = 1
        return renderer.nsImage
    }

    private func renderCachedPanelImage(colorScheme: ColorScheme) -> NSImage? {
        let host = makeHostingView(colorScheme: colorScheme)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func makeHostingView(colorScheme: ColorScheme) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: makePanel().environment(\.colorScheme, colorScheme))
        host.frame = NSRect(x: 0, y: 0, width: 472, height: 720)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 472, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return host
    }

    private func makePanel() -> some View {
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
            networkConnections: [],
            processDetails: [],
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
            networkConnections: [],
            processDetails: [],
            sampledAt: Date(timeIntervalSince1970: 103)
        )
        let state = ServerHostMetricsState(
            snapshot: current,
            previousSnapshot: previous,
            isLoading: false,
            errorMessage: nil,
            lastAttemptAt: current.sampledAt
        )

        return ServerMetricsPanel(
            hostTitle: "root@192.0.2.10:22",
            connectionState: "Connected",
            state: state
        )
    }

    private func sampleColor(in image: NSImage?, x: Int, y: Int) -> NSColor? {
        guard let tiff = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              x >= 0,
              y >= 0,
              x < bitmap.pixelsWide,
              y < bitmap.pixelsHigh
        else {
            return nil
        }
        return bitmap.colorAt(x: x, y: y)
    }
}
