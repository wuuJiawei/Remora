import AppKit
import SwiftUI
import Testing
@testable import RemoraApp

@Suite(.serialized)
@MainActor
struct SessionMetricsTooltipTests {
    @Test
    func placementCentersTooltipOnHoveredTagWhenSpaceAllows() {
        let offset = SessionMetricsTooltipPlacement.xOffset(
            anchorFrame: CGRect(x: 560, y: 0, width: 28, height: 18),
            tooltipWidth: 144,
            containerWidth: 1200
        )

        #expect(offset == 502)
    }

    @Test
    func tooltipStyleUsesReadableBackgroundAndVisibleMotionTimings() {
        #expect(SessionMetricsTooltipStyle.backgroundOpacity == 1.0)
        #expect(SessionMetricsTooltipStyle.shadowOpacity >= 0.16)
        #expect(SessionMetricsTooltipStyle.enterDuration > 0)
        #expect(SessionMetricsTooltipStyle.exitDuration > 0)
    }

    @Test
    func cachedHoverAnchorFrameIsReusedWhenHoverStartsWithoutFreshGeometry() {
        var anchor = SessionMetricsHoverAnchorState()
        anchor.update(frame: CGRect(x: 24, y: 12, width: 36, height: 18))

        let resolved = anchor.resolvedFrame(explicitFrame: nil)

        #expect(resolved == CGRect(x: 24, y: 12, width: 36, height: 18))
    }

    @Test
    func rendersInLightAndDarkAppearances() {
        assertTooltipRendering(for: .light)
        assertTooltipRendering(for: .dark)
    }

    private func assertTooltipRendering(for colorScheme: ColorScheme) {
        let snapshot = ServerResourceMetricsSnapshot(
            cpuFraction: 0.37,
            memoryFraction: 0.58,
            swapFraction: 0.11,
            diskFraction: 0.29,
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
            topProcesses: [],
            filesystems: [],
            networkConnections: [],
            processDetails: [],
            sampledAt: Date(timeIntervalSince1970: 103)
        )

        let host = NSHostingView(
            rootView: SessionMetricsTooltip(
                hostTitle: "root@192.0.2.10:22",
                connectionState: "Connected",
                snapshot: snapshot,
                isLoading: false,
                errorMessage: nil
            )
            .environment(\.colorScheme, colorScheme)
        )
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 180)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let imageRep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        #expect(imageRep != nil, "Tooltip should create a cached display image in \(String(describing: colorScheme)) mode.")
        if let imageRep {
            host.cacheDisplay(in: host.bounds, to: imageRep)
            #expect(imageRep.pixelsWide > 0)
            #expect(imageRep.pixelsHigh > 0)
        }
        #expect(host.fittingSize.width >= 136, "Tooltip should remain readable in \(String(describing: colorScheme)) mode.")
        #expect(host.fittingSize.width <= 190, "Tooltip should fit tightly to its content in \(String(describing: colorScheme)) mode.")
        #expect(host.fittingSize.height >= 110, "Tooltip should preserve readable height in \(String(describing: colorScheme)) mode.")
    }
}
