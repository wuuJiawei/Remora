import SwiftUI

struct SessionTabBarItem: View {
    let title: String
    let tabID: UUID
    @ObservedObject var runtime: TerminalRuntime
    let metricsState: ServerHostMetricsState?
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onOpenMetricsWindow: () -> Void
    let onClose: () -> Void
    let onMetricsHoverChange: (HoveredSessionMetricsTooltip?) -> Void
    let accessibilityIdentifier: String
    @State private var isHovering = false
    @State private var isMetricsPopoverPresented = false

    private var shouldShowMetrics: Bool {
        runtime.connectionMode == .ssh
    }

    private var targetCapabilitiesAvailable: Bool {
        runtime.reconnectableSSHHost?.connectionRoute.isTargetBound == true
    }

    private var hostDisplayTitle: String {
        guard let host = runtime.connectedSSHHost else { return title }
        return "\(host.username)@\(host.address):\(host.port)"
    }

    private var compactFractions: [Double?] {
        let snapshot = metricsState?.snapshot
        return [
            snapshot?.cpuFraction,
            snapshot?.memoryFraction,
            snapshot?.diskFraction,
        ]
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Text(title)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VisualStyle.textPrimary)
            }
            .buttonStyle(.plain)

            if shouldShowMetrics {
                Button(action: onOpenMetricsWindow) {
                    SessionMetricCompactBars(
                        fractions: compactFractions,
                        isLoading: metricsState?.isLoading ?? false
                    )
                }
                .buttonStyle(.plain)
                .disabled(runtime.connectedSSHHost == nil || !targetCapabilitiesAvailable)
                .help(
                    targetCapabilitiesAvailable
                        ? tr("Open server status window")
                        : tr("Select a JumpServer asset and account before using Docker, files, or server metrics.")
                )
                .anchorPreference(
                    key: SessionMetricsButtonAnchorPreferenceKey.self,
                    value: .bounds,
                    transform: { anchor in
                        isMetricsPopoverPresented ? [tabID: anchor] : [:]
                    }
                )
                .onHover { hovering in
                    isMetricsPopoverPresented = hovering
                    if hovering {
                        reportMetricsHoverIfNeeded()
                    } else {
                        onMetricsHoverChange(nil)
                    }
                }
                .accessibilityIdentifier("session-tab-metrics")
            }

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? VisualStyle.leftSelectedBackground : (isHovering ? VisualStyle.leftHoverBackground : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? VisualStyle.borderStrong : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .onChange(of: runtime.connectionMode) {
            if runtime.connectionMode != .ssh {
                isMetricsPopoverPresented = false
                onMetricsHoverChange(nil)
            }
        }
        .onChange(of: metricsState) { _, _ in
            reportMetricsHoverIfNeeded()
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func reportMetricsHoverIfNeeded() {
        guard isMetricsPopoverPresented, shouldShowMetrics, targetCapabilitiesAvailable else {
            return
        }

        onMetricsHoverChange(
            HoveredSessionMetricsTooltip(
                tabID: tabID,
                hostTitle: hostDisplayTitle,
                connectionState: localizedConnectionState(runtime.connectionState),
                snapshot: metricsState?.snapshot,
                isLoading: metricsState?.isLoading ?? false,
                errorMessage: metricsState?.errorMessage
            )
        )
    }
}

struct SessionMetricCompactBars: View {
    let fractions: [Double?]
    let isLoading: Bool

    private let colors: [Color] = [.green, .orange, .blue]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(fractions.enumerated()), id: \.offset) { index, fraction in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                        .fill(VisualStyle.metricTrackBackground)
                    RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                        .fill(colors[index].opacity(0.9))
                        .frame(height: barHeight(for: fraction))
                }
                .frame(width: 4, height: 13)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(VisualStyle.elevatedSurfaceBackground)
        )
    }

    private func barHeight(for fraction: Double?) -> CGFloat {
        let fallback = isLoading ? 0.16 : 0.05
        let resolved = fraction ?? fallback
        return max(1, CGFloat(min(max(resolved, 0), 1)) * 13)
    }
}
