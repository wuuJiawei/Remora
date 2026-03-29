import Foundation
import SwiftUI

struct ServerMetricsDelta: Equatable, Sendable {
    let networkRXBytesPerSecond: Int64?
    let networkTXBytesPerSecond: Int64?
    let diskReadBytesPerSecond: Int64?
    let diskWriteBytesPerSecond: Int64?

    static func between(
        previous: ServerResourceMetricsSnapshot?,
        current: ServerResourceMetricsSnapshot?
    ) -> ServerMetricsDelta {
        guard let previous, let current else {
            return ServerMetricsDelta(
                networkRXBytesPerSecond: nil,
                networkTXBytesPerSecond: nil,
                diskReadBytesPerSecond: nil,
                diskWriteBytesPerSecond: nil
            )
        }

        let elapsed = current.sampledAt.timeIntervalSince(previous.sampledAt)
        guard elapsed > 0 else {
            return ServerMetricsDelta(
                networkRXBytesPerSecond: nil,
                networkTXBytesPerSecond: nil,
                diskReadBytesPerSecond: nil,
                diskWriteBytesPerSecond: nil
            )
        }

        return ServerMetricsDelta(
            networkRXBytesPerSecond: rate(current.networkRXBytes, previous.networkRXBytes, elapsed: elapsed),
            networkTXBytesPerSecond: rate(current.networkTXBytes, previous.networkTXBytes, elapsed: elapsed),
            diskReadBytesPerSecond: rate(current.diskReadBytes, previous.diskReadBytes, elapsed: elapsed),
            diskWriteBytesPerSecond: rate(current.diskWriteBytes, previous.diskWriteBytes, elapsed: elapsed)
        )
    }

    private static func rate(_ current: Int64?, _ previous: Int64?, elapsed: TimeInterval) -> Int64? {
        guard let current, let previous, current >= previous else { return nil }
        let delta = current - previous
        return Int64((Double(delta) / elapsed).rounded(.down))
    }
}

enum ServerMonitoringTab: Hashable {
    case system
    case network
    case process
}

struct ServerMetricsPanel: View {
    let hostTitle: String
    let hostSubtitle: String
    let connectionState: String
    let state: ServerHostMetricsState

    @State private var selectedTab: ServerMonitoringTab
    @State private var networkSearchQuery: String
    @State private var processSearchQuery: String
    @State private var networkSortOption: ServerMonitoringNetworkSortOption
    @State private var processSortOption: ServerMonitoringProcessSortOption
    @State private var networkSortDirection: ServerMonitoringSortDirection
    @State private var processSortDirection: ServerMonitoringSortDirection

    init(
        hostTitle: String,
        hostSubtitle: String,
        connectionState: String,
        state: ServerHostMetricsState,
        initialTab: ServerMonitoringTab = .system
    ) {
        self.hostTitle = hostTitle
        self.hostSubtitle = hostSubtitle
        self.connectionState = connectionState
        self.state = state
        _selectedTab = State(initialValue: initialTab)
        _networkSearchQuery = State(initialValue: "")
        _processSearchQuery = State(initialValue: "")
        _networkSortOption = State(initialValue: ServerMonitoringSortOrder.defaultNetworkOption)
        _processSortOption = State(initialValue: ServerMonitoringSortOrder.defaultProcessOption)
        _networkSortDirection = State(initialValue: ServerMonitoringSortOrder.defaultNetworkDirection)
        _processSortDirection = State(initialValue: ServerMonitoringSortOrder.defaultProcessDirection)
    }

    private var snapshot: ServerResourceMetricsSnapshot? { state.snapshot }
    private var delta: ServerMetricsDelta {
        ServerMetricsDelta.between(previous: state.previousSnapshot, current: state.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabPicker
            if selectedTab == .system {
                header
            }
            content
        }
        .frame(minWidth: 500, idealWidth: 560, maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("server-metrics-panel")
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            Text(tr("System Information Monitoring"))
                .tag(ServerMonitoringTab.system)
            Text(tr("Network Monitoring"))
                .tag(ServerMonitoringTab.network)
            Text(tr("Process Monitoring"))
                .tag(ServerMonitoringTab.process)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var filteredNetworkConnections: [ServerNetworkConnectionMetric] {
        let rows = snapshot?.networkConnections ?? []
        let query = normalizedSearchQuery(networkSearchQuery)
        let filtered = rows.filter { row in
            guard !query.isEmpty else { return true }
            return [
                row.processName,
                row.listenAddress,
                row.port.map(String.init) ?? "",
                row.pid.map(String.init) ?? ""
            ]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted(using: ServerMonitoringSortOrder.comparators(for: networkSortOption, direction: networkSortDirection))
    }

    private var filteredProcessDetails: [ServerProcessDetailsMetric] {
        let rows = snapshot?.processDetails ?? []
        let query = normalizedSearchQuery(processSearchQuery)
        let filtered = rows.filter { row in
            guard !query.isEmpty else { return true }
            return [
                row.command,
                row.user,
                row.location,
                row.pid.map(String.init) ?? ""
            ]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted(using: ServerMonitoringSortOrder.comparators(for: processSortOption, direction: processSortDirection))
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .system:
            systemTab
        case .network:
            networkTab
        case .process:
            processTab
        }
    }

    @ViewBuilder
    private var systemTab: some View {
        if let snapshot {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    summarySection(snapshot)
                    overviewSection(snapshot)
                    processSection(snapshot)
                    transferSection(snapshot)
                    filesystemSection(snapshot)
                    footer(snapshot)
                }
                .padding(.top, 2)
            }
        } else {
            loadingOrErrorPlaceholder
        }
    }

    @ViewBuilder
    private var networkTab: some View {
        if let snapshot {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    networkControls

                    if snapshot.networkConnections.isEmpty {
                        ContentUnavailableView(
                            tr("No network monitoring data yet."),
                            systemImage: "network",
                            description: Text(tr("Network activity rows will appear after the next successful sampling cycle."))
                        )
                    } else if filteredNetworkConnections.isEmpty {
                        ContentUnavailableView(
                            tr("No matching network monitoring results."),
                            systemImage: "magnifyingglass",
                            description: Text(tr("Try a different keyword or sort option."))
                        )
                    } else {
                        ForEach(filteredNetworkConnections) { row in
                            networkConnectionRow(row)
                        }
                        footer(snapshot)
                    }
                }
                .padding(.top, 2)
            }
        } else {
            loadingOrErrorPlaceholder
        }
    }

    @ViewBuilder
    private var processTab: some View {
        if let snapshot {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    processControls

                    if snapshot.processDetails.isEmpty {
                        ContentUnavailableView(
                            tr("No process monitoring data yet."),
                            systemImage: "list.bullet.rectangle.portrait",
                            description: Text(tr("Process rows will appear after the next successful sampling cycle."))
                        )
                    } else if filteredProcessDetails.isEmpty {
                        ContentUnavailableView(
                            tr("No matching process monitoring results."),
                            systemImage: "magnifyingglass",
                            description: Text(tr("Try a different keyword or sort option."))
                        )
                    } else {
                        ForEach(filteredProcessDetails) { row in
                            processDetailsRow(row)
                        }
                        footer(snapshot)
                    }
                }
                .padding(.top, 2)
            }
        } else {
            loadingOrErrorPlaceholder
        }
    }

    @ViewBuilder
    private var loadingOrErrorPlaceholder: some View {
        if state.isLoading {
            ServerMetricsPlaceholderCard(
                title: tr("Collecting metrics…"),
                message: tr("Remora is sampling the remote host for CPU, memory, traffic, and process details.")
            )
        } else if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
            ServerMetricsPlaceholderCard(
                title: tr("Metrics unavailable"),
                message: errorMessage,
                accent: .red
            )
        } else {
            ServerMetricsPlaceholderCard(
                title: tr("No metrics yet."),
                message: tr("Metrics will appear after the first sampling cycle.")
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Server Monitoring"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(VisualStyle.textPrimary)

            Text(hostTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
                .lineLimit(1)

            Text(hostSubtitle)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textSecondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                ServerMetricsInfoChip(
                    title: tr("State"),
                    value: connectionState,
                    tint: .accentColor
                )

                if let snapshot {
                    ServerMetricsInfoChip(
                        title: tr("Load"),
                        value: formatLoads(snapshot),
                        tint: .orange
                    )
                    ServerMetricsInfoChip(
                        title: tr("Uptime"),
                        value: formatUptime(snapshot.uptimeSeconds),
                        tint: .green
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(VisualStyle.elevatedSurfaceBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func summarySection(_ snapshot: ServerResourceMetricsSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ServerMetricsStatTile(title: tr("Load 1m"), value: formatLoad(snapshot.loadAverage1), tint: .orange)
            ServerMetricsStatTile(title: tr("Load 5m"), value: formatLoad(snapshot.loadAverage5), tint: .yellow)
            ServerMetricsStatTile(title: tr("Load 15m"), value: formatLoad(snapshot.loadAverage15), tint: .brown)
            ServerMetricsStatTile(title: tr("Processes"), value: formatCount(snapshot.processCount), tint: .mint)
        }
    }

    private func overviewSection(_ snapshot: ServerResourceMetricsSnapshot) -> some View {
        ServerMetricsSectionCard(title: tr("Resources"), accent: .blue, accessibilityID: "server-metrics-card-resources") {
            VStack(spacing: 8) {
                ServerMetricsUsageRow(
                    title: tr("CPU"),
                    detail: formatPercent(snapshot.cpuFraction),
                    secondaryDetail: formatLoads(snapshot),
                    fraction: snapshot.cpuFraction,
                    tint: .green
                )
                ServerMetricsUsageRow(
                    title: tr("Memory"),
                    detail: formatPercent(snapshot.memoryFraction),
                    secondaryDetail: "\(formatBytes(snapshot.memoryUsedBytes))/\(formatBytes(snapshot.memoryTotalBytes))",
                    fraction: snapshot.memoryFraction,
                    tint: .orange
                )
                ServerMetricsUsageRow(
                    title: tr("Swap"),
                    detail: formatPercent(snapshot.swapFraction),
                    secondaryDetail: "\(formatBytes(snapshot.swapUsedBytes))/\(formatBytes(snapshot.swapTotalBytes))",
                    fraction: snapshot.swapFraction,
                    tint: .purple
                )
                ServerMetricsUsageRow(
                    title: tr("Disk"),
                    detail: formatPercent(snapshot.diskFraction),
                    secondaryDetail: "\(formatBytes(snapshot.diskUsedBytes))/\(formatBytes(snapshot.diskTotalBytes))",
                    fraction: snapshot.diskFraction,
                    tint: .blue
                )
            }
        }
    }

    @ViewBuilder
    private func processSection(_ snapshot: ServerResourceMetricsSnapshot) -> some View {
        if !snapshot.topProcesses.isEmpty {
            ServerMetricsSectionCard(title: tr("Top Processes"), accent: .orange, accessibilityID: "server-metrics-card-processes") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        headerLabel(tr("Memory"), width: 66)
                        headerLabel(tr("CPU"), width: 40)
                        headerLabel(tr("Command"), width: nil)
                    }

                    ForEach(Array(snapshot.topProcesses.enumerated()), id: \.offset) { _, process in
                        HStack(spacing: 8) {
                            bodyLabel(formatBytes(process.memoryBytes), width: 66)
                            bodyLabel(formatCPUPercent(process.cpuPercent), width: 40)
                            bodyLabel(process.command, width: nil, alignment: .leading)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func transferSection(_ snapshot: ServerResourceMetricsSnapshot) -> some View {
        ServerMetricsSectionCard(title: tr("Network & Disk IO"), accent: .mint, accessibilityID: "server-metrics-card-transfer") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ServerMetricsStatTile(title: tr("RX/s"), value: formatRate(delta.networkRXBytesPerSecond), tint: .green)
                    ServerMetricsStatTile(title: tr("TX/s"), value: formatRate(delta.networkTXBytesPerSecond), tint: .mint)
                }
                HStack(spacing: 8) {
                    ServerMetricsStatTile(title: tr("Read/s"), value: formatRate(delta.diskReadBytesPerSecond), tint: .blue)
                    ServerMetricsStatTile(title: tr("Write/s"), value: formatRate(delta.diskWriteBytesPerSecond), tint: .purple)
                }

                VStack(alignment: .leading, spacing: 4) {
                    inlineStat(tr("Processes"), formatCount(snapshot.processCount))
                    inlineStat(tr("RX total"), formatBytes(snapshot.networkRXBytes))
                    inlineStat(tr("TX total"), formatBytes(snapshot.networkTXBytes))
                    inlineStat(tr("Disk read total"), formatBytes(snapshot.diskReadBytes))
                    inlineStat(tr("Disk write total"), formatBytes(snapshot.diskWriteBytes))
                }
            }
        }
    }

    @ViewBuilder
    private func filesystemSection(_ snapshot: ServerResourceMetricsSnapshot) -> some View {
        if !snapshot.filesystems.isEmpty {
            ServerMetricsSectionCard(title: tr("Filesystems"), accent: .blue, accessibilityID: "server-metrics-card-filesystems") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        headerLabel(tr("Path"), width: 92)
                        headerLabel(tr("Available / Size"), width: nil)
                    }

                    ForEach(Array(snapshot.filesystems.enumerated()), id: \.offset) { _, filesystem in
                        HStack(spacing: 8) {
                            bodyLabel(filesystem.mountPath, width: 92, alignment: .leading)
                                .lineLimit(1)
                            bodyLabel(
                                "\(formatBytes(filesystem.availableBytes))/\(formatBytes(filesystem.totalBytes))",
                                width: nil,
                                alignment: .leading
                            )
                            .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var networkControls: some View {
        HStack(spacing: 8) {
            TextField(tr("Search"), text: $networkSearchQuery, prompt: Text(tr("Search network monitoring")))
                .textFieldStyle(.roundedBorder)

            Menu {
                Picker(tr("Sort"), selection: $networkSortOption) {
                    Text(tr("Connections"))
                        .tag(ServerMonitoringNetworkSortOption.connections)
                    Text(tr("IP Count"))
                        .tag(ServerMonitoringNetworkSortOption.remoteAddressCount)
                    Text(tr("Port"))
                        .tag(ServerMonitoringNetworkSortOption.port)
                    Text(tr("Name"))
                        .tag(ServerMonitoringNetworkSortOption.processName)
                    Text(tr("Upload"))
                        .tag(ServerMonitoringNetworkSortOption.sentBytes)
                    Text(tr("Download"))
                        .tag(ServerMonitoringNetworkSortOption.receivedBytes)
                    Text(tr("PID"))
                        .tag(ServerMonitoringNetworkSortOption.pid)
                }

                Divider()

                Button(tr("Ascending")) {
                    networkSortDirection = .ascending
                }
                Button(tr("Descending")) {
                    networkSortDirection = .descending
                }
            } label: {
                Label(tr("Sort"), systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)

            directionToggle(direction: $networkSortDirection)
        }
        .padding(.horizontal, 2)
    }

    private var processControls: some View {
        HStack(spacing: 8) {
            TextField(tr("Search"), text: $processSearchQuery, prompt: Text(tr("Search process monitoring")))
                .textFieldStyle(.roundedBorder)

            Menu {
                Picker(tr("Sort"), selection: $processSortOption) {
                    Text(tr("CPU"))
                        .tag(ServerMonitoringProcessSortOption.cpu)
                    Text(tr("Memory"))
                        .tag(ServerMonitoringProcessSortOption.memory)
                    Text(tr("PID"))
                        .tag(ServerMonitoringProcessSortOption.pid)
                    Text(tr("Command"))
                        .tag(ServerMonitoringProcessSortOption.command)
                    Text(tr("User"))
                        .tag(ServerMonitoringProcessSortOption.user)
                }

                Divider()

                Button(tr("Ascending")) {
                    processSortDirection = .ascending
                }
                Button(tr("Descending")) {
                    processSortDirection = .descending
                }
            } label: {
                Label(tr("Sort"), systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)

            directionToggle(direction: $processSortDirection)
        }
        .padding(.horizontal, 2)
    }

    private func networkConnectionRow(_ row: ServerNetworkConnectionMetric) -> some View {
        ServerMetricsListCard {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        rowTitle(row.processName)
                        Spacer(minLength: 8)
                        networkMetaRow(row)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            rowTitle(row.processName)
                            Spacer(minLength: 8)
                            compactBadge(title: tr("PID"), value: row.pid.map(String.init) ?? "--", tint: .accentColor)
                        }
                        networkMetaRow(row)
                    }
                }
                Text("\(row.listenAddress):\(row.port.map(String.init) ?? "--")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func processDetailsRow(_ row: ServerProcessDetailsMetric) -> some View {
        ServerMetricsListCard {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        rowTitle(row.command)
                        Spacer(minLength: 8)
                        processMetaRow(row)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            rowTitle(row.command)
                            Spacer(minLength: 8)
                            compactBadge(title: tr("PID"), value: row.pid.map(String.init) ?? "--", tint: .accentColor)
                        }
                        processMetaRow(row)
                    }
                }
                Text(row.location)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func footer(_ snapshot: ServerResourceMetricsSnapshot) -> some View {
        Text("\(tr("Last sample")): \(formatTimestamp(snapshot.sampledAt))")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(VisualStyle.textTertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func headerLabel(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(VisualStyle.textSecondary)
            .frame(width: width, alignment: .leading)
    }

    private func bodyLabel(_ text: String, width: CGFloat?, alignment: Alignment = .trailing) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(VisualStyle.textPrimary)
            .frame(width: width, alignment: alignment)
    }

    private func inlineStat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
    }

    private func formatLoads(_ snapshot: ServerResourceMetricsSnapshot) -> String {
        [snapshot.loadAverage1, snapshot.loadAverage5, snapshot.loadAverage15]
            .map { value in
                guard let value else { return "--" }
                return String(format: "%.2f", value)
            }
            .joined(separator: " ")
    }

    private func formatLoad(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
    }

    private func formatPercent(_ fraction: Double?) -> String {
        guard let fraction else { return "--" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private func formatCPUPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f%%", value)
    }

    private func formatBytes(_ value: Int64?) -> String {
        guard let value else { return "--" }
        if value == 0 {
            return "0 KB"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .binary
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }

    private func formatRate(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return "\(formatBytes(value))/s"
    }

    private func formatCount(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return "\(value)"
    }

    private func formatInteger(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value)"
    }

    private func formatUptime(_ seconds: Int64?) -> String {
        guard let seconds, seconds >= 0 else { return "--" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
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

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(VisualStyle.textPrimary)
            .lineLimit(1)
    }

    private func networkMetaRow(_ row: ServerNetworkConnectionMetric) -> some View {
        HStack(spacing: 6) {
            compactBadge(title: tr("PID"), value: row.pid.map(String.init) ?? "--", tint: .accentColor)
            compactBadge(title: tr("Connections"), value: formatInteger(row.connectionCount), tint: .orange)
            compactBadge(title: tr("IP Count"), value: formatInteger(row.remoteAddressCount), tint: .blue)
            compactBadge(title: tr("Upload"), value: formatBytes(row.sentBytes), tint: .mint)
            compactBadge(title: tr("Download"), value: formatBytes(row.receivedBytes), tint: .green)
        }
    }

    private func processMetaRow(_ row: ServerProcessDetailsMetric) -> some View {
        HStack(spacing: 6) {
            compactBadge(title: tr("PID"), value: row.pid.map(String.init) ?? "--", tint: .accentColor)
            compactBadge(title: tr("User"), value: row.user, tint: .purple)
            compactBadge(title: tr("CPU"), value: formatCPUPercent(row.cpuPercent), tint: .orange)
            compactBadge(title: tr("Memory"), value: formatBytes(row.memoryBytes), tint: .blue)
        }
    }

    private func directionToggle(direction: Binding<ServerMonitoringSortDirection>) -> some View {
        Button {
            direction.wrappedValue = direction.wrappedValue == .descending ? .ascending : .descending
        } label: {
            Image(systemName: direction.wrappedValue == .descending ? "arrow.down" : "arrow.up")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(direction.wrappedValue == .descending ? tr("Descending") : tr("Ascending"))
    }

    private func normalizedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactBadge(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.08), in: Capsule())
    }
}

private struct ServerMetricsSectionCard<Content: View>: View {
    let title: String
    let accent: Color
    let accessibilityID: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent.opacity(0.14), in: Capsule())

            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VisualStyle.elevatedSurfaceBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
        .accessibilityIdentifier(accessibilityID ?? "")
    }
}

private struct ServerMetricsUsageRow: View {
    let title: String
    let detail: String
    let secondaryDetail: String
    let fraction: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VisualStyle.textPrimary)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(secondaryDetail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VisualStyle.textSecondary)
            }

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(VisualStyle.metricTrackBackground)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tint.opacity(0.88))
                            .frame(width: max(6, proxy.size.width * CGFloat(min(max(fraction ?? 0.04, 0), 1))))
                    }
            }
            .frame(height: 8)
        }
    }
}

private struct ServerMetricsStatTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ServerMetricsInfoChip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ServerMetricsPlaceholderCard: View {
    let title: String
    let message: String
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(VisualStyle.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }
}

private struct ServerMetricsListCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VisualStyle.elevatedSurfaceBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }
}
