import AppKit
import Foundation
import Testing
@testable import RemoraApp
import RemoraCore

@Suite(.serialized)
@MainActor
struct ServerStatusWindowTests {
    @Test
    func silentRefreshDoesNotChangeLayoutDuringLoading() async {
        _ = NSApplication.shared

        let manager = ServerStatusWindowManager()
        let metricsCenter = ServerMetricsCenter(
            activeRefreshInterval: 0,
            inactiveRefreshInterval: 0,
            retentionInterval: 45,
            maxConcurrentFetches: 1
        )
        let runtime = TerminalRuntime()
        let host = Host(
            name: "prod-api",
            address: "192.0.2.10",
            username: "root",
            group: "Production",
            auth: HostAuth(method: .agent)
        )

        manager.present(host: host, runtime: runtime, metricsCenter: metricsCenter)
        defer { closeServerStatusWindows() }

        let initialHeight = serverStatusWindowContentHeight()

        let didEnterLoadingState = await waitUntil(timeout: 2) {
            metricsCenter.state(for: host)?.isLoading == true
        }

        let loadingHeight = serverStatusWindowContentHeight()

        #expect(didEnterLoadingState, "Server Metrics should enter a loading state for the presented host.")
        #expect(loadingHeight == initialHeight, "Server Status should not grow when metrics refresh silently.")
    }

    @Test
    func monitoringWindowUsesExpandedDashboardWidth() async {
        _ = NSApplication.shared

        let manager = ServerStatusWindowManager()
        let metricsCenter = ServerMetricsCenter(
            activeRefreshInterval: 0,
            inactiveRefreshInterval: 0,
            retentionInterval: 45,
            maxConcurrentFetches: 1
        )
        let runtime = TerminalRuntime()
        let host = Host(
            name: "prod-api",
            address: "192.0.2.10",
            username: "root",
            group: "Production",
            auth: HostAuth(method: .agent)
        )

        manager.present(host: host, runtime: runtime, metricsCenter: metricsCenter)
        defer { closeServerStatusWindows() }

        let width = serverStatusWindows().first?.frame.width ?? 0
        #expect(width >= 592, "Server Status window should keep a compact monitoring width.")
        #expect(width <= 640, "Server Status window should no longer open as an oversized dashboard.")
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await MainActor.run(body: condition)
    }

    private func serverStatusWindowContentHeight() -> CGFloat {
        guard let contentView = serverStatusWindows().first?.contentView else { return 0 }
        contentView.layoutSubtreeIfNeeded()
        return max(contentView.fittingSize.height, contentView.intrinsicContentSize.height)
    }

    private func serverStatusWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue == "remora.server-status-window" }
    }

    private func closeServerStatusWindows() {
        for window in serverStatusWindows() {
            window.orderOut(nil)
            window.close()
        }
    }
}
