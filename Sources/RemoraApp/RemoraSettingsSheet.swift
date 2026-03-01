import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case tags
    case sidebar
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .tags:
            return "Tags"
        case .sidebar:
            return "Sidebar"
        case .advanced:
            return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general:
            return "gearshape"
        case .tags:
            return "tag"
        case .sidebar:
            return "sidebar.left"
        case .advanced:
            return "gearshape.2"
        }
    }

    var accessibilityIdentifier: String {
        "settings-tab-\(rawValue)"
    }
}

struct RemoraSettingsSheet: View {
    private enum SettingsFocusField: Hashable {
        case downloadDirectoryPath
    }

    @State private var selectedPane: SettingsPane = .sidebar
    @State private var downloadDirectoryDraft = ""
    @State private var downloadDirectoryHighlight = false
    @State private var downloadDirectoryJumpToken = 0
    @FocusState private var focusedField: SettingsFocusField?

    @AppStorage("settings.general.openSessionOnLaunch") private var openSessionOnLaunch = true
    @AppStorage("settings.general.confirmBeforeClosingTab") private var confirmBeforeClosingTab = true
    @AppStorage("settings.general.reopenLastWorkspace") private var reopenLastWorkspace = true
    @AppStorage("settings.general.defaultShell") private var defaultShell = "/bin/zsh"
    @AppStorage(AppSettings.appearanceModeKey) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppSettings.downloadDirectoryPathKey) private var downloadDirectoryPath = AppSettings.defaultDownloadDirectoryURL().path

    @AppStorage("settings.tags.enableThreadTags") private var enableThreadTags = true
    @AppStorage("settings.tags.showColoredDots") private var showColoredDots = true
    @AppStorage("settings.tags.defaultTagColor") private var defaultTagColor = "Blue"

    @AppStorage("settings.sidebar.showRecent") private var showRecentInSidebar = true
    @AppStorage("settings.sidebar.showShared") private var showSharedInSidebar = true
    @AppStorage("settings.sidebar.showFavorites") private var showFavoritesInSidebar = true
    @AppStorage("settings.sidebar.showArchived") private var showArchivedInSidebar = false
    @AppStorage("settings.sidebar.defaultGroupSort") private var sidebarSort = "Pinned first"

    @AppStorage("settings.advanced.preferSFTP") private var preferSFTP = true
    @AppStorage("settings.advanced.showConnectionDiagnostics") private var showConnectionDiagnostics = false
    @AppStorage("settings.advanced.sshConnectTimeout") private var sshConnectTimeout = 10
    @AppStorage(AppSettings.serverMetricsActiveRefreshSecondsKey)
    private var serverMetricsActiveRefreshSeconds = AppSettings.defaultServerMetricsActiveRefreshSeconds
    @AppStorage(AppSettings.serverMetricsInactiveRefreshSecondsKey)
    private var serverMetricsInactiveRefreshSeconds = AppSettings.defaultServerMetricsInactiveRefreshSeconds
    @AppStorage(AppSettings.serverMetricsMaxConcurrentFetchesKey)
    private var serverMetricsMaxConcurrentFetches = AppSettings.defaultServerMetricsMaxConcurrentFetches

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 660, minHeight: 410)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("settings-window")
        .onAppear {
            syncDownloadDirectoryDraftFromStorage()
            normalizeServerMetricsSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoraOpenDownloadDirectorySetting)) { _ in
            focusDownloadDirectorySetting()
        }
        .onChange(of: serverMetricsActiveRefreshSeconds) {
            normalizeServerMetricsSettings()
        }
        .onChange(of: serverMetricsInactiveRefreshSeconds) {
            normalizeServerMetricsSettings()
        }
        .onChange(of: serverMetricsMaxConcurrentFetches) {
            normalizeServerMetricsSettings()
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SettingsPane.allCases) { pane in
                    paneButton(pane)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        Group {
            switch selectedPane {
            case .general:
                generalPane
            case .tags:
                tagsPane
            case .sidebar:
                sidebarPane
            case .advanced:
                advancedPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(VisualStyle.leftSidebarBackground.opacity(0.62))
    }

    private func paneButton(_ pane: SettingsPane) -> some View {
        let isSelected = selectedPane == pane
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                selectedPane = pane
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: pane.icon)
                    .font(.system(size: 18, weight: .regular))
                Text(pane.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.accentColor : VisualStyle.textSecondary)
            .frame(width: 92, height: 62)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.9) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(pane.accessibilityIdentifier)
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
            Form {
                Toggle("Open one local terminal session on launch", isOn: $openSessionOnLaunch)
                    .toggleStyle(.checkbox)
                Toggle("Confirm before closing an active session tab", isOn: $confirmBeforeClosingTab)
                    .toggleStyle(.checkbox)
                Toggle("Reopen the last selected workspace on launch", isOn: $reopenLastWorkspace)
                    .toggleStyle(.checkbox)

                Picker("Default local shell", selection: $defaultShell) {
                    Text("zsh").tag("/bin/zsh")
                    Text("bash").tag("/bin/bash")
                    Text("fish").tag("/opt/homebrew/bin/fish")
                }
                .frame(maxWidth: 260, alignment: .leading)

                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { AppAppearanceMode.resolved(from: appearanceModeRawValue) },
                        set: { mode in
                            appearanceModeRawValue = mode.rawValue
                        }
                    )
                ) {
                    Text("System").tag(AppAppearanceMode.system)
                    Text("Light").tag(AppAppearanceMode.light)
                    Text("Dark").tag(AppAppearanceMode.dark)
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .formStyle(.grouped)
            .font(.system(size: 13))

            Text("File Manager")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Download directory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VisualStyle.textPrimary)

                HStack(spacing: 8) {
                    TextField("Download directory", text: $downloadDirectoryDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .focused($focusedField, equals: .downloadDirectoryPath)
                        .onSubmit {
                            applyDownloadDirectoryDraft()
                        }
                        .accessibilityIdentifier("settings-download-path-field")

                    Button("Choose…") {
                        chooseDownloadDirectory()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-download-path-choose")
                }

                Text("Used by File Manager downloads and transfer queue.")
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(downloadDirectoryHighlight ? 0.95 : 0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(downloadDirectoryHighlight ? Color.accentColor : VisualStyle.borderSoft, lineWidth: downloadDirectoryHighlight ? 1.6 : 1)
            )
            .animation(.easeInOut(duration: 0.2), value: downloadDirectoryHighlight)
            .accessibilityIdentifier("settings-download-path-row")

            Spacer(minLength: 0)
        }
        .onChange(of: downloadDirectoryJumpToken) {
            focusedField = .downloadDirectoryPath
            pulseDownloadDirectoryHighlight()
        }
        .accessibilityIdentifier("settings-section-general")
    }

    private var tagsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tagging")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
            Form {
                Toggle("Enable tags for SSH threads", isOn: $enableThreadTags)
                    .toggleStyle(.checkbox)
                Toggle("Show tag color dots in the sidebar list", isOn: $showColoredDots)
                    .toggleStyle(.checkbox)

                Picker("Default tag color", selection: $defaultTagColor) {
                    Text("Blue").tag("Blue")
                    Text("Green").tag("Green")
                    Text("Orange").tag("Orange")
                    Text("Red").tag("Red")
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            .formStyle(.grouped)
            .font(.system(size: 13))
        }
        .accessibilityIdentifier("settings-section-tags")
    }

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Show these items in the sidebar:")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Recent", isOn: $showRecentInSidebar)
                    .toggleStyle(.checkbox)
                Toggle("Shared", isOn: $showSharedInSidebar)
                    .toggleStyle(.checkbox)
                Toggle("Favorites", isOn: $showFavoritesInSidebar)
                    .toggleStyle(.checkbox)
                Toggle("Archived", isOn: $showArchivedInSidebar)
                    .toggleStyle(.checkbox)
            }
            .font(.system(size: 14, weight: .regular))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VisualStyle.borderSoft, lineWidth: 1)
            )

            Picker("Default group sorting", selection: $sidebarSort) {
                Text("Pinned first").tag("Pinned first")
                Text("Alphabetical").tag("Alphabetical")
                Text("Recently used").tag("Recently used")
            }
            .frame(maxWidth: 280, alignment: .leading)

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("settings-section-sidebar")
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Advanced")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Form {
                Toggle("Prefer SFTP for file operations and fallback to SSH when needed", isOn: $preferSFTP)
                    .toggleStyle(.checkbox)
                Toggle("Show connection diagnostics in session status", isOn: $showConnectionDiagnostics)
                    .toggleStyle(.checkbox)

                HStack(spacing: 12) {
                    Text("SSH connect timeout (seconds)")
                    Stepper(value: $sshConnectTimeout, in: 3...60) {
                        Text("\(sshConnectTimeout)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 120)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Server metrics sampling")
                        .font(.system(size: 13, weight: .semibold))

                    HStack(spacing: 12) {
                        Text("Active tab refresh (seconds)")
                        Stepper(value: $serverMetricsActiveRefreshSeconds, in: 2...30) {
                            Text("\(serverMetricsActiveRefreshSeconds)")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 120)
                        .accessibilityIdentifier("settings-metrics-active-refresh")
                    }

                    HStack(spacing: 12) {
                        Text("Inactive tab refresh (seconds)")
                        Stepper(value: $serverMetricsInactiveRefreshSeconds, in: 4...90) {
                            Text("\(serverMetricsInactiveRefreshSeconds)")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 120)
                        .accessibilityIdentifier("settings-metrics-inactive-refresh")
                    }

                    HStack(spacing: 12) {
                        Text("Max concurrent metric fetches")
                        Stepper(value: $serverMetricsMaxConcurrentFetches, in: 1...6) {
                            Text("\(serverMetricsMaxConcurrentFetches)")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 120)
                        .accessibilityIdentifier("settings-metrics-max-concurrency")
                    }
                }
            }
            .formStyle(.grouped)
            .font(.system(size: 13))

            Text("Higher refresh and concurrency improve responsiveness but increase local and remote load.")
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
        }
        .accessibilityIdentifier("settings-section-advanced")
    }

    private func focusDownloadDirectorySetting() {
        syncDownloadDirectoryDraftFromStorage()
        withAnimation(.easeInOut(duration: 0.12)) {
            selectedPane = .general
        }
        DispatchQueue.main.async {
            downloadDirectoryJumpToken += 1
        }
    }

    private func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = resolvedDownloadDirectoryURL(from: downloadDirectoryDraft)

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }
        downloadDirectoryDraft = selectedURL.standardizedFileURL.path
        applyDownloadDirectoryDraft()
    }

    private func applyDownloadDirectoryDraft() {
        let resolvedURL = resolvedDownloadDirectoryURL(from: downloadDirectoryDraft)
        downloadDirectoryDraft = resolvedURL.path
        guard downloadDirectoryPath != resolvedURL.path else { return }
        downloadDirectoryPath = resolvedURL.path
        NotificationCenter.default.post(
            name: .remoraDownloadDirectoryDidChange,
            object: resolvedURL.path,
            userInfo: ["path": resolvedURL.path]
        )
    }

    private func syncDownloadDirectoryDraftFromStorage() {
        let resolvedURL = resolvedDownloadDirectoryURL(from: downloadDirectoryPath)
        if downloadDirectoryPath != resolvedURL.path {
            downloadDirectoryPath = resolvedURL.path
            NotificationCenter.default.post(
                name: .remoraDownloadDirectoryDidChange,
                object: resolvedURL.path,
                userInfo: ["path": resolvedURL.path]
            )
        }
        if downloadDirectoryDraft != resolvedURL.path {
            downloadDirectoryDraft = resolvedURL.path
        }
    }

    private func resolvedDownloadDirectoryURL(from rawPath: String) -> URL {
        AppSettings.resolvedDownloadDirectoryURL(from: rawPath)
    }

    private func pulseDownloadDirectoryHighlight() {
        downloadDirectoryHighlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            downloadDirectoryHighlight = false
        }
    }

    private func normalizeServerMetricsSettings() {
        let normalizedActive = AppSettings.clampedServerMetricsActiveRefreshSeconds(serverMetricsActiveRefreshSeconds)
        let normalizedInactiveCandidate = AppSettings.clampedServerMetricsInactiveRefreshSeconds(serverMetricsInactiveRefreshSeconds)
        let normalizedInactive = max(normalizedInactiveCandidate, normalizedActive)
        let normalizedConcurrent = AppSettings.clampedServerMetricsMaxConcurrentFetches(serverMetricsMaxConcurrentFetches)

        if normalizedActive != serverMetricsActiveRefreshSeconds {
            serverMetricsActiveRefreshSeconds = normalizedActive
        }
        if normalizedInactive != serverMetricsInactiveRefreshSeconds {
            serverMetricsInactiveRefreshSeconds = normalizedInactive
        }
        if normalizedConcurrent != serverMetricsMaxConcurrentFetches {
            serverMetricsMaxConcurrentFetches = normalizedConcurrent
        }
    }

}
