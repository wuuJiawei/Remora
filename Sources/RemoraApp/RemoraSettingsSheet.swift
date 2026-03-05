import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case ai
    case shortcuts
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .ai:
            return "AI"
        case .shortcuts:
            return "Shortcuts"
        case .advanced:
            return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general:
            return "gearshape"
        case .ai:
            return "sparkles"
        case .shortcuts:
            return "keyboard"
        case .advanced:
            return "slider.horizontal.3"
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

    @State private var selectedPane: SettingsPane = .general
    @State private var downloadDirectoryDraft = ""
    @State private var downloadDirectoryHighlight = false
    @State private var downloadDirectoryJumpToken = 0
    @State private var recordingShortcutCommand: AppShortcutCommand?
    @State private var shortcutRecorderMonitor: Any?
    @State private var shortcutRecorderMessage: String?
    @State private var shortcutRecorderIsError = false
    @FocusState private var focusedField: SettingsFocusField?
    @EnvironmentObject private var keyboardShortcutStore: AppKeyboardShortcutStore
    @Environment(\.openURL) private var openURL

    @AppStorage(AppSettings.languageModeKey) private var languageModeRawValue = AppLanguageMode.system.rawValue
    @AppStorage(AppSettings.appearanceModeKey) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppSettings.downloadDirectoryPathKey) private var downloadDirectoryPath = AppSettings.defaultDownloadDirectoryURL().path
    @AppStorage(AppSettings.serverMetricsActiveRefreshSecondsKey)
    private var serverMetricsActiveRefreshSeconds = AppSettings.defaultServerMetricsActiveRefreshSeconds
    @AppStorage(AppSettings.serverMetricsInactiveRefreshSecondsKey)
    private var serverMetricsInactiveRefreshSeconds = AppSettings.defaultServerMetricsInactiveRefreshSeconds
    @AppStorage(AppSettings.serverMetricsMaxConcurrentFetchesKey)
    private var serverMetricsMaxConcurrentFetches = AppSettings.defaultServerMetricsMaxConcurrentFetches
    @AppStorage(AppSettings.aiProviderKey)
    private var aiProviderRawValue = AppSettings.defaultAIProvider.rawValue
    @AppStorage(AppSettings.aiModelIDKey)
    private var aiModelID = AppSettings.defaultAIModelID
    @AppStorage(AppSettings.aiModelDisplayNameKey)
    private var aiModelDisplayName = AppSettings.defaultAIModelDisplayName
    @AppStorage(AppSettings.aiTemperatureKey)
    private var aiTemperature = AppSettings.defaultAITemperature
    @AppStorage(AppSettings.aiMaxOutputTokensKey)
    private var aiMaxOutputTokens = AppSettings.defaultAIMaxOutputTokens
    @AppStorage(AppSettings.aiStreamingEnabledKey)
    private var aiStreamingEnabled = AppSettings.defaultAIStreamingEnabled

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("settings-window")
        .onAppear {
            syncDownloadDirectoryDraftFromStorage()
            normalizeServerMetricsSettings()
            normalizeAISettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoraOpenDownloadDirectorySetting)) { _ in
            focusDownloadDirectorySetting()
        }
        .onDisappear {
            stopShortcutCapture(clearSelection: true)
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
        .onChange(of: aiTemperature) {
            normalizeAISettings()
        }
        .onChange(of: aiMaxOutputTokens) {
            normalizeAISettings()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(SettingsPane.allCases) { pane in
                paneButton(pane)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var content: some View {
        Group {
            switch selectedPane {
            case .general:
                generalPane
            case .ai:
                aiPane
            case .shortcuts:
                shortcutsPane
            case .advanced:
                advancedPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(VisualStyle.settingsPaneBackground)
    }

    private func paneButton(_ pane: SettingsPane) -> some View {
        let isSelected = selectedPane == pane
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                selectedPane = pane
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pane.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(tr(pane.title))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.accentColor : VisualStyle.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? VisualStyle.settingsSelectedTabBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(pane.accessibilityIdentifier)
    }

    private var generalPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                settingsSectionCard(
                    title: tr("Application"),
                    message: tr("Language changes are applied immediately.")
                ) {
                    compactSettingRow(title: tr("Language")) {
                        Picker(
                            tr("Language"),
                            selection: Binding(
                                get: { AppLanguageMode.resolved(from: languageModeRawValue) },
                                set: { mode in
                                    languageModeRawValue = mode.rawValue
                                }
                            )
                        ) {
                            Text(tr("Follow System")).tag(AppLanguageMode.system)
                            Text(tr("English")).tag(AppLanguageMode.english)
                            Text(tr("Simplified Chinese")).tag(AppLanguageMode.simplifiedChinese)
                        }
                        .labelsHidden()
                        .frame(width: 220, alignment: .trailing)
                    }

                    compactSettingRow(title: tr("Appearance")) {
                        Picker(
                            tr("Appearance"),
                            selection: Binding(
                                get: { AppAppearanceMode.resolved(from: appearanceModeRawValue) },
                                set: { mode in
                                    appearanceModeRawValue = mode.rawValue
                                }
                            )
                        ) {
                            Text(tr("System")).tag(AppAppearanceMode.system)
                            Text(tr("Light")).tag(AppAppearanceMode.light)
                            Text(tr("Dark")).tag(AppAppearanceMode.dark)
                        }
                        .labelsHidden()
                        .frame(width: 220, alignment: .trailing)
                    }
                }

                settingsSectionCard(
                    title: tr("File Manager"),
                    message: tr("Used by File Manager downloads and transfer queue."),
                    highlight: downloadDirectoryHighlight
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField(tr("Download directory"), text: $downloadDirectoryDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .focused($focusedField, equals: .downloadDirectoryPath)
                                .onSubmit {
                                    applyDownloadDirectoryDraft()
                                }
                                .accessibilityIdentifier("settings-download-path-field")

                            Button(tr("Choose…")) {
                                chooseDownloadDirectory()
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings-download-path-choose")
                        }
                    }
                    .accessibilityIdentifier("settings-download-path-row")
                }

                settingsSectionCard(
                    title: tr("About Remora"),
                    message: tr("Open-source home and feedback channel.")
                ) {
                    compactSettingRow(title: tr("Version")) {
                        Text(appVersionText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(VisualStyle.textSecondary)
                    }

                    HStack(spacing: 8) {
                        Button(tr("View on GitHub")) {
                            openURL(AppLinks.repositoryURL)
                        }
                        .controlSize(.small)

                        Button(tr("Report an issue")) {
                            openURL(AppLinks.issuesURL)
                        }
                        .controlSize(.small)
                    }

                    Text(tr("Issues require repository access while the repository is private."))
                        .font(.system(size: 11))
                        .foregroundStyle(VisualStyle.textTertiary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .onChange(of: downloadDirectoryJumpToken) {
            focusedField = .downloadDirectoryPath
            pulseDownloadDirectoryHighlight()
        }
        .accessibilityIdentifier("settings-section-general")
    }

    private var aiPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                settingsSectionCard(
                    title: tr("AI Provider & Model"),
                    message: tr("Set provider and model defaults used by session AI when no per-session override is configured.")
                ) {
                    compactSettingRow(title: tr("Provider")) {
                        Picker(tr("Provider"), selection: aiProviderBinding) {
                            ForEach(AIProviderOption.allCases) { provider in
                                Text(tr(provider.title)).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220, alignment: .trailing)
                        .accessibilityIdentifier("settings-ai-provider")
                    }

                    compactSettingRow(title: tr("Recommended model")) {
                        Picker(tr("Recommended model"), selection: suggestedModelSelectionBinding) {
                            ForEach(selectedAIProvider.suggestedModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                            Text(tr("Custom model")).tag(customModelSelectionTag)
                        }
                        .labelsHidden()
                        .frame(width: 220, alignment: .trailing)
                        .accessibilityIdentifier("settings-ai-model-recommended")
                    }

                    compactSettingRow(title: tr("Model ID")) {
                        TextField(tr("Model ID"), text: $aiModelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 220, alignment: .trailing)
                            .accessibilityIdentifier("settings-ai-model-id")
                    }

                    compactSettingRow(title: tr("Model display name")) {
                        TextField(tr("Model display name"), text: $aiModelDisplayName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220, alignment: .trailing)
                            .accessibilityIdentifier("settings-ai-model-name")
                    }
                }

                settingsSectionCard(
                    title: tr("AI Inference"),
                    message: tr("Use conservative defaults first and tune based on quality and cost.")
                ) {
                    compactSettingRow(title: tr("Temperature")) {
                        HStack(spacing: 8) {
                            Slider(value: $aiTemperature, in: 0.0...2.0, step: 0.05)
                                .frame(width: 150)
                            Text(String(format: "%.2f", aiTemperature))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(VisualStyle.textSecondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .accessibilityIdentifier("settings-ai-temperature")
                    }

                    compactSettingRow(title: tr("Max output tokens")) {
                        Stepper(value: $aiMaxOutputTokens, in: 256...8_192, step: 128) {
                            Text("\(aiMaxOutputTokens)")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 160, alignment: .trailing)
                        .accessibilityIdentifier("settings-ai-max-output-tokens")
                    }

                    compactSettingRow(title: tr("Stream responses")) {
                        Toggle(tr("Stream responses"), isOn: $aiStreamingEnabled)
                            .labelsHidden()
                            .accessibilityIdentifier("settings-ai-streaming")
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("settings-section-ai")
    }

    private var advancedPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                settingsSectionCard(
                    title: tr("Server metrics sampling"),
                    message: tr("Higher refresh and concurrency improve responsiveness but increase local and remote load.")
                ) {
                    compactSettingRow(title: tr("Active tab refresh (seconds)")) {
                        Stepper(value: $serverMetricsActiveRefreshSeconds, in: 2...30) {
                            Text("\(serverMetricsActiveRefreshSeconds)")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 140, alignment: .trailing)
                        .accessibilityIdentifier("settings-metrics-active-refresh")
                    }

                    compactSettingRow(title: tr("Inactive tab refresh (seconds)")) {
                        Stepper(value: $serverMetricsInactiveRefreshSeconds, in: 4...90) {
                            Text("\(serverMetricsInactiveRefreshSeconds)")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 140, alignment: .trailing)
                        .accessibilityIdentifier("settings-metrics-inactive-refresh")
                    }

                    compactSettingRow(title: tr("Max concurrent metric fetches")) {
                        Stepper(value: $serverMetricsMaxConcurrentFetches, in: 1...6) {
                            Text("\(serverMetricsMaxConcurrentFetches)")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 140, alignment: .trailing)
                        .accessibilityIdentifier("settings-metrics-max-concurrency")
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("settings-section-advanced")
    }

    private var shortcutsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                settingsSectionCard(
                    title: tr("Keyboard Shortcuts"),
                    message: tr("Use common shortcuts and customize them for your workflow.")
                ) {
                    shortcutConflictsCard

                    if let shortcutRecorderMessage {
                        Label(shortcutRecorderMessage, systemImage: shortcutRecorderIsError ? "exclamationmark.triangle.fill" : "keyboard")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(shortcutRecorderIsError ? Color.orange : VisualStyle.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(VisualStyle.settingsSubtleBackground)
                            )
                    }

                    VStack(spacing: 6) {
                        ForEach(AppShortcutCommand.allCases) { command in
                            shortcutRow(for: command)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("settings-section-shortcuts")
    }

    private func settingsSectionCard<Content: View>(
        title: String,
        message: String? = nil,
        highlight: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
            }

            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VisualStyle.settingsSurfaceBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(highlight ? Color.accentColor : VisualStyle.borderSoft, lineWidth: highlight ? 1.5 : 1)
        )
        .animation(.easeInOut(duration: 0.2), value: highlight)
    }

    private func compactSettingRow<Control: View>(
        title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(VisualStyle.textPrimary)
            Spacer(minLength: 10)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customModelSelectionTag: String {
        "__custom_model__"
    }

    private var selectedAIProvider: AIProviderOption {
        AppSettings.resolvedAIProvider(from: aiProviderRawValue)
    }

    private var aiProviderBinding: Binding<AIProviderOption> {
        Binding(
            get: { selectedAIProvider },
            set: { provider in
                aiProviderRawValue = provider.rawValue
                aiModelID = AppSettings.defaultAIModelID(for: provider)
                aiModelDisplayName = AppSettings.defaultAIModelDisplayName(for: provider)
            }
        )
    }

    private var suggestedModelSelectionBinding: Binding<String> {
        Binding(
            get: {
                if selectedAIProvider.suggestedModels.contains(where: { $0.id == aiModelID }) {
                    return aiModelID
                }
                return customModelSelectionTag
            },
            set: { selected in
                guard selected != customModelSelectionTag else { return }
                guard let preset = selectedAIProvider.suggestedModels.first(where: { $0.id == selected }) else { return }
                aiModelID = preset.id
                aiModelDisplayName = preset.displayName
            }
        )
    }

    private var shortcutConflictsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: keyboardShortcutStore.conflicts.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(keyboardShortcutStore.conflicts.isEmpty ? Color.green : Color.orange)
                Text(tr("Shortcut conflicts"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VisualStyle.textPrimary)
            }

            if keyboardShortcutStore.conflicts.isEmpty {
                Text(tr("No shortcut conflicts detected."))
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(keyboardShortcutStore.conflicts) { conflict in
                        let commandNames = conflict.commands
                            .map { commandTitle(for: $0) }
                            .joined(separator: " / ")
                        Text("\(conflict.shortcut.displayText)  \(commandNames)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(VisualStyle.textPrimary)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VisualStyle.settingsSubtleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(keyboardShortcutStore.conflicts.isEmpty ? VisualStyle.borderSoft : Color.orange.opacity(0.8), lineWidth: 1)
        )
    }

    private func shortcutRow(for command: AppShortcutCommand) -> some View {
        let isRecording = recordingShortcutCommand == command
        let displayShortcut = keyboardShortcutStore.shortcut(for: command)?.displayText ?? tr("Not Set")
        let hasConflict = keyboardShortcutStore.conflict(for: command) != nil
        let isCustomized = keyboardShortcutStore.hasCustomBinding(for: command)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(commandTitle(for: command))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VisualStyle.textPrimary)

                    if hasConflict {
                        Text(tr("Conflict with another command"))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                    } else if isCustomized {
                        Text(tr("Customized"))
                            .font(.system(size: 11))
                            .foregroundStyle(VisualStyle.textSecondary)
                    }
                }

                Spacer(minLength: 6)

                Button {
                    beginShortcutCapture(for: command)
                } label: {
                    Text(isRecording ? tr("Press shortcut...") : displayShortcut)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isRecording ? Color.accentColor : VisualStyle.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .frame(minWidth: 108)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VisualStyle.inputFieldBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    isRecording ? Color.accentColor : (hasConflict ? Color.orange.opacity(0.85) : VisualStyle.borderSoft),
                                    lineWidth: isRecording ? 1.5 : 1
                                )
                        )
                }
                .buttonStyle(.plain)

                Button(tr("Unbind")) {
                    keyboardShortcutStore.unbindShortcut(for: command)
                    if recordingShortcutCommand == command {
                        stopShortcutCapture(clearSelection: true)
                    }
                }
                .controlSize(.small)

                Button(tr("Default")) {
                    keyboardShortcutStore.restoreDefault(for: command)
                    if recordingShortcutCommand == command {
                        stopShortcutCapture(clearSelection: true)
                    }
                }
                .controlSize(.small)
                .disabled(!isCustomized)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VisualStyle.settingsSubtleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(hasConflict ? Color.orange.opacity(0.85) : VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func beginShortcutCapture(for command: AppShortcutCommand) {
        stopShortcutCapture(clearSelection: true)
        recordingShortcutCommand = command
        shortcutRecorderMessage = tr("Press a key combination now. Press Esc to cancel.")
        shortcutRecorderIsError = false

        shortcutRecorderMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleShortcutRecorderEvent(event)
        }
    }

    private func stopShortcutCapture(clearSelection: Bool) {
        if let shortcutRecorderMonitor {
            NSEvent.removeMonitor(shortcutRecorderMonitor)
            self.shortcutRecorderMonitor = nil
        }
        if clearSelection {
            recordingShortcutCommand = nil
        }
    }

    private func handleShortcutRecorderEvent(_ event: NSEvent) -> NSEvent? {
        guard let command = recordingShortcutCommand else {
            return event
        }

        if event.keyCode == 53 {
            shortcutRecorderMessage = tr("Shortcut update canceled.")
            shortcutRecorderIsError = false
            stopShortcutCapture(clearSelection: true)
            return nil
        }

        guard let shortcut = AppKeyboardShortcut.from(event: event) else {
            shortcutRecorderMessage = tr("Shortcut must include Command, Option, or Control.")
            shortcutRecorderIsError = true
            NSSound.beep()
            return nil
        }

        keyboardShortcutStore.setShortcut(shortcut, for: command)
        shortcutRecorderMessage = "\(commandTitle(for: command)) \(tr("updated to")) \(shortcut.displayText)"
        shortcutRecorderIsError = false
        stopShortcutCapture(clearSelection: true)
        return nil
    }

    private func commandTitle(for command: AppShortcutCommand) -> String {
        L10n.tr(command.titleKey, fallback: command.fallbackTitle)
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
        panel.prompt = tr("Choose…")
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

    private func normalizeAISettings() {
        let resolvedProvider = AppSettings.resolvedAIProvider(from: aiProviderRawValue)
        if resolvedProvider.rawValue != aiProviderRawValue {
            aiProviderRawValue = resolvedProvider.rawValue
        }

        let normalizedTemperature = AppSettings.clampedAITemperature(aiTemperature)
        if normalizedTemperature != aiTemperature {
            aiTemperature = normalizedTemperature
        }

        let normalizedMaxOutputTokens = AppSettings.clampedAIMaxOutputTokens(aiMaxOutputTokens)
        if normalizedMaxOutputTokens != aiMaxOutputTokens {
            aiMaxOutputTokens = normalizedMaxOutputTokens
        }

        let trimmedModelID = aiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModelID.isEmpty {
            aiModelID = AppSettings.defaultAIModelID(for: resolvedProvider)
        } else if trimmedModelID != aiModelID {
            aiModelID = trimmedModelID
        }

        let trimmedDisplayName = aiModelDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDisplayName.isEmpty {
            aiModelDisplayName = AppSettings.defaultAIModelDisplayName(for: resolvedProvider)
        } else if trimmedDisplayName != aiModelDisplayName {
            aiModelDisplayName = trimmedDisplayName
        }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (shortVersion, build) {
        case let (short?, build?) where !short.isEmpty && !build.isEmpty:
            return "\(short) (\(build))"
        case let (short?, _) where !short.isEmpty:
            return short
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return "dev"
        }
    }

    private func tr(_ key: String) -> String {
        L10n.tr(key, fallback: key)
    }
}
