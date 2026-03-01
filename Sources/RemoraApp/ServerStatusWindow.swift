import AppKit
import SwiftUI
import RemoraCore

@MainActor
final class ServerStatusWindowManager: ObservableObject {
    private let context = ServerStatusWindowContext()
    private var window: NSWindow?

    func present(
        host: RemoraCore.Host,
        runtime: TerminalRuntime,
        metricsCenter: ServerMetricsCenter
    ) {
        context.host = host
        context.runtime = runtime

        if window == nil {
            createWindow(metricsCenter: metricsCenter)
        }
        positionWindowBesidePrimaryWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow(metricsCenter: ServerMetricsCenter) {
        let rootView = ServerStatusWindowView(context: context, metricsCenter: metricsCenter)
        let hostingController = NSHostingController(rootView: rootView)
        let nextWindow = NSWindow(contentViewController: hostingController)
        nextWindow.title = "Server Status"
        nextWindow.identifier = NSUserInterfaceItemIdentifier("remora.server-status-window")
        nextWindow.styleMask = [.titled, .closable, .miniaturizable]
        nextWindow.setContentSize(NSSize(width: 300, height: 620))
        nextWindow.minSize = NSSize(width: 300, height: 480)
        nextWindow.isReleasedWhenClosed = false
        window = nextWindow
    }

    private func positionWindowBesidePrimaryWindow() {
        guard let window else { return }

        let anchorWindow: NSWindow? = {
            if let keyWindow = NSApp.keyWindow, keyWindow != window {
                return keyWindow
            }
            if let mainWindow = NSApp.mainWindow, mainWindow != window {
                return mainWindow
            }
            return NSApp.windows.first(where: { $0.isVisible && $0 != window })
        }()

        guard let anchorWindow else { return }

        let anchorFrame = anchorWindow.frame
        var targetFrame = window.frame
        targetFrame.origin.x = anchorFrame.maxX + 14
        targetFrame.origin.y = anchorFrame.maxY - targetFrame.height

        let visibleFrame = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        if let visibleFrame {
            if targetFrame.maxX > visibleFrame.maxX {
                targetFrame.origin.x = visibleFrame.maxX - targetFrame.width
            }
            if targetFrame.minY < visibleFrame.minY {
                targetFrame.origin.y = visibleFrame.minY
            }
            if targetFrame.maxY > visibleFrame.maxY {
                targetFrame.origin.y = visibleFrame.maxY - targetFrame.height
            }
            if targetFrame.minX < visibleFrame.minX {
                targetFrame.origin.x = visibleFrame.minX
            }
        }

        window.setFrame(targetFrame, display: true)
    }
}

@MainActor
final class ServerStatusWindowContext: ObservableObject {
    @Published var host: RemoraCore.Host?
    @Published var runtime: TerminalRuntime?
}

private struct ServerStatusWindowView: View {
    @ObservedObject var context: ServerStatusWindowContext
    @ObservedObject var metricsCenter: ServerMetricsCenter
    @State private var isExtendedMetricsExpanded = true

    var body: some View {
        ZStack {
            VisualStyle.rightPanelBackground
                .ignoresSafeArea()
            if let host = context.host {
                statusContent(for: host)
            } else {
                ContentUnavailableView(
                    "No Server Selected",
                    systemImage: "waveform.path.ecg",
                    description: Text("Click metrics bars in a session tab to inspect server status.")
                )
            }
        }
        .frame(minWidth: 300, minHeight: 480)
        .frame(width: 300)
    }

    private func statusContent(for host: RemoraCore.Host) -> some View {
        let state = metricsCenter.state(for: host) ?? .idle
        let snapshot = state.snapshot
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Status")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(VisualStyle.textPrimary)
                    Text("\(host.username)@\(host.address):\(host.port)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(VisualStyle.textSecondary)
                    Text(context.runtime?.connectionState ?? "Disconnected")
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textSecondary)
                }

                HStack(alignment: .bottom, spacing: 16) {
                    ServerStatusMetricColumn(
                        title: "CPU",
                        fraction: snapshot?.cpuFraction,
                        color: .green
                    )
                    ServerStatusMetricColumn(
                        title: "MEM",
                        fraction: snapshot?.memoryFraction,
                        color: .orange
                    )
                    ServerStatusMetricColumn(
                        title: "DISK",
                        fraction: snapshot?.diskFraction,
                        color: .blue
                    )
                }
                .padding(.vertical, 2)

                Divider()
                    .overlay(VisualStyle.borderSoft)

                VStack(alignment: .leading, spacing: 5) {
                    statusLine("Memory", "\(formatBytes(snapshot?.memoryUsedBytes))/\(formatBytes(snapshot?.memoryTotalBytes))")
                    statusLine("Disk", "\(formatBytes(snapshot?.diskUsedBytes))/\(formatBytes(snapshot?.diskTotalBytes))")
                    statusLine("Load(1m)", formatLoad(snapshot?.loadAverage1))
                    statusLine("Uptime", formatUptime(snapshot?.uptimeSeconds))
                    statusLine("Sampled", snapshot.map { formatTimestamp($0.sampledAt) } ?? "--")
                }
                .font(.system(size: 12, design: .monospaced))

                DisclosureGroup(isExpanded: $isExtendedMetricsExpanded) {
                    VStack(alignment: .leading, spacing: 5) {
                        statusLine("Processes", formatCount(snapshot?.processCount))
                        statusLine("Net RX", formatBytes(snapshot?.networkRXBytes))
                        statusLine("Net TX", formatBytes(snapshot?.networkTXBytes))
                        statusLine("Disk Read", formatBytes(snapshot?.diskReadBytes))
                        statusLine("Disk Write", formatBytes(snapshot?.diskWriteBytes))
                        Text("Network and disk IO values are cumulative since server boot.")
                            .font(.system(size: 11))
                            .foregroundStyle(VisualStyle.textSecondary)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Process / Network / Disk IO")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VisualStyle.textPrimary)
                }
                .animation(.easeInOut(duration: 0.16), value: isExtendedMetricsExpanded)

                if state.isLoading {
                    Text("Refreshing metrics…")
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textSecondary)
                }

                if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(5)
                }
            }
            .padding(14)
        }
    }

    private func statusLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .foregroundStyle(VisualStyle.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private func formatBytes(_ value: Int64?) -> String {
        guard let value else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }

    private func formatLoad(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
    }

    private func formatUptime(_ seconds: Int64?) -> String {
        guard let seconds, seconds >= 0 else { return "--" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatCount(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return "\(value)"
    }
}

private struct ServerStatusMetricColumn: View {
    let title: String
    let fraction: Double?
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.1))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.9))
                    .frame(height: max(2, CGFloat(clampedFraction) * 156))
            }
            .frame(width: 46, height: 156)

            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
    }

    private var clampedFraction: Double {
        guard let fraction else { return 0.03 }
        return min(max(fraction, 0), 1)
    }
}
