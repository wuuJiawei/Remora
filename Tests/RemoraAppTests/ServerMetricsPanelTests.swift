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
            sampleColor(in: image, x: 250, y: y)
        }
        #expect(samples.contains { color in
            guard let color else { return false }
            return color.alphaComponent > 0.01
        })
    }

    @Test
    func networkTabRendersAtTableFriendlyWidth() {
        let image = renderPanelImage(colorScheme: ColorScheme.light, initialTab: .network)
        #expect(image != nil)
        #expect(image?.size.width ?? 0 >= 500)
        #expect(image?.size.width ?? 0 <= 620)
    }

    @Test
    func processTabRendersAtTableFriendlyWidth() {
        let image = renderPanelImage(colorScheme: ColorScheme.dark, initialTab: .process)
        #expect(image != nil)
        #expect(image?.size.width ?? 0 >= 500)
        #expect(image?.size.width ?? 0 <= 620)
    }

    @Test
    func processTabKeepsLongCommandsSingleLine() {
        let image = renderPanelImage(colorScheme: ColorScheme.dark, initialTab: .process, useLongProcessCommand: true)
        #expect(image != nil)
        #expect(image?.size.height ?? 0 <= 720)
    }

    private func assertPanelRendering(for colorScheme: ColorScheme) {
        let image = renderPanelImage(colorScheme: colorScheme)
        #expect(image != nil, "Panel should render in \(String(describing: colorScheme)) mode.")
        #expect(image?.size.width ?? 0 >= 500, "Rendered panel should keep a readable dashboard width in \(String(describing: colorScheme)) mode.")
        #expect(image?.size.height ?? 0 >= 300, "Rendered panel should keep a readable height in \(String(describing: colorScheme)) mode.")
    }

    private func renderPanelImage(
        colorScheme: ColorScheme,
        initialTab: ServerMonitoringTab = .system,
        useLongProcessCommand: Bool = false
    ) -> NSImage? {
        let renderer = ImageRenderer(
            content: makePanel(initialTab: initialTab, useLongProcessCommand: useLongProcessCommand)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.proposedSize = ProposedViewSize(width: 560, height: 720)
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

    private func makeHostingView(colorScheme: ColorScheme, initialTab: ServerMonitoringTab = .system) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(makePanel(initialTab: initialTab).environment(\.colorScheme, colorScheme)))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 720)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
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

    private func makePanel(
        initialTab: ServerMonitoringTab = .system,
        useLongProcessCommand: Bool = false
    ) -> some View {
        let processCommand = useLongProcessCommand
            ? "python3 ... python3 ... python3 ... python3 ... python3 ... python3 ..."
            : "redis-server"
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
            networkConnections: [
                ServerNetworkConnectionMetric(pid: 1263, processName: "sshd", listenAddress: "0.0.0.0", port: 22, remoteAddressCount: 1, connectionCount: 1, sentBytes: 900, receivedBytes: 300)
            ],
            processDetails: [
                ServerProcessDetailsMetric(pid: 1383, user: "redis", memoryBytes: 12_517_376, cpuPercent: 0.3, command: processCommand, location: "/www/server/redis/src/redis-server")
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
            networkConnections: [
                ServerNetworkConnectionMetric(pid: 1263, processName: "sshd", listenAddress: "0.0.0.0", port: 22, remoteAddressCount: 1, connectionCount: 2, sentBytes: 1_433, receivedBytes: 560),
                ServerNetworkConnectionMetric(pid: 1128, processName: "python3", listenAddress: "0.0.0.0", port: 8888, remoteAddressCount: 40, connectionCount: 55, sentBytes: 0, receivedBytes: 0)
            ],
            processDetails: [
                ServerProcessDetailsMetric(pid: 783_214, user: "root", memoryBytes: 99_719_168, cpuPercent: 5.0, command: "AliYunDunMonito", location: "/usr/local/aegis/aegis_client/aegis_12_91/AliYunDunMonitor"),
                ServerProcessDetailsMetric(pid: 1383, user: "redis", memoryBytes: 12_533_760, cpuPercent: 0.3, command: processCommand, location: "/www/server/redis/src/redis-server")
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

        return ServerMetricsPanel(
            hostTitle: "prod-api",
            hostSubtitle: "root@192.0.2.10:22",
            connectionState: "Connected",
            state: state,
            initialTab: initialTab
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
