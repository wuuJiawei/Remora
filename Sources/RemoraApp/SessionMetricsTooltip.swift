import Foundation
import SwiftUI

struct SessionMetricsTooltip: View {
    let hostTitle: String
    let connectionState: String
    let snapshot: ServerResourceMetricsSnapshot?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        SessionMetricsTooltipCard(
            hostTitle: hostTitle,
            connectionState: connectionState,
            snapshot: snapshot,
            isLoading: isLoading,
            errorMessage: errorMessage
        )
        .padding(10)
        .background(VisualStyle.elevatedSurfaceBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
}

struct SessionMetricsTooltipCard: View {
    let hostTitle: String
    let connectionState: String
    let snapshot: ServerResourceMetricsSnapshot?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hostTitle)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
                .lineLimit(1)

            Text(connectionState)
                .font(.system(size: 11))
                .foregroundStyle(VisualStyle.textSecondary)
                .lineLimit(1)

            HStack(alignment: .bottom, spacing: 12) {
                SessionMetricDetailBar(
                    title: tr("CPU"),
                    fraction: snapshot?.cpuFraction,
                    color: .green,
                    isLoading: isLoading
                )
                SessionMetricDetailBar(
                    title: tr("MEM"),
                    fraction: snapshot?.memoryFraction,
                    color: .orange,
                    isLoading: isLoading
                )
                SessionMetricDetailBar(
                    title: tr("DISK"),
                    fraction: snapshot?.diskFraction,
                    color: .blue,
                    isLoading: isLoading
                )
            }

            if let snapshot {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(tr("Memory")): \(formatMetricByteValue(snapshot.memoryUsedBytes))/\(formatMetricByteValue(snapshot.memoryTotalBytes))")
                    Text("\(tr("Disk")): \(formatMetricByteValue(snapshot.diskUsedBytes))/\(formatMetricByteValue(snapshot.diskTotalBytes))")
                    Text("\(tr("Sampled")): \(formatMetricSampleTimestamp(snapshot.sampledAt))")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VisualStyle.textSecondary)
            } else if isLoading {
                Text(tr("Loading server metrics…"))
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textSecondary)
            } else if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else {
                Text(tr("No metrics yet."))
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textSecondary)
            }
        }
        .frame(width: 214, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SessionMetricDetailBar: View {
    let title: String
    let fraction: Double?
    let color: Color
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(VisualStyle.metricTrackBackground)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.9))
                    .frame(height: resolvedHeight)
            }
            .frame(width: 16, height: 72)

            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(formatMetricPercent(fraction))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
    }

    private var resolvedHeight: CGFloat {
        let fallback = isLoading ? 0.16 : 0.05
        let resolved = fraction ?? fallback
        return max(1, CGFloat(min(max(resolved, 0), 1)) * 72)
    }
}

private func formatMetricPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
}

private func formatMetricByteValue(_ bytes: Int64?) -> String {
    guard let bytes else { return "--" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .binary
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

private func formatMetricSampleTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}
