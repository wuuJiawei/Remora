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
    @Binding var isPresented: Bool
    @State private var selectedPane: SettingsPane = .sidebar

    @AppStorage("settings.general.openSessionOnLaunch") private var openSessionOnLaunch = true
    @AppStorage("settings.general.confirmBeforeClosingTab") private var confirmBeforeClosingTab = true
    @AppStorage("settings.general.reopenLastWorkspace") private var reopenLastWorkspace = true
    @AppStorage("settings.general.defaultShell") private var defaultShell = "/bin/zsh"

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 700, height: 460)
        .background(VisualStyle.leftSidebarBackground)
        .accessibilityIdentifier("settings-sheet")
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("Preferences")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
                .padding(.top, 12)
                .accessibilityIdentifier("settings-sheet-title")

            HStack(spacing: 14) {
                ForEach(SettingsPane.allCases) { pane in
                    paneButton(pane)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Text("Changes are saved automatically.")
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
            Spacer()
            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("settings-done")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                    .font(.system(size: 24, weight: .regular))
                Text(pane.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.accentColor : VisualStyle.textSecondary)
            .frame(width: 124, height: 82)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.9) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(pane.accessibilityIdentifier)
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            }
            .formStyle(.grouped)
            .font(.system(size: 13))
        }
        .accessibilityIdentifier("settings-section-general")
    }

    private var tagsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 14) {
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
        VStack(alignment: .leading, spacing: 10) {
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
            }
            .formStyle(.grouped)
            .font(.system(size: 13))

            Text("These options are intended for troubleshooting and larger team setups.")
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
        }
        .accessibilityIdentifier("settings-section-advanced")
    }
}
