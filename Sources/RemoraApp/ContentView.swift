import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import RemoraCore

private struct ActiveRuntimeSFTPState: Equatable {
    var runtimeID: ObjectIdentifier?
    var connectionMode: ConnectionMode?
    var connectionState: String
    var hostSignature: String?
}

private struct HostExportDraft: Equatable {
    var scope: HostExportScope = .all
    var format: HostExportFormat = .json
    var includeSavedPasswords = false
}

@MainActor
struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @StateObject private var workspace = WorkspaceViewModel()
    @StateObject private var hostCatalog = HostCatalogStore()
    @StateObject private var fileTransfer = FileTransferViewModel()
    @StateObject private var directorySyncBridge = TerminalDirectorySyncBridge()
    @StateObject private var serverMetricsCenter = ServerMetricsCenter()
    @StateObject private var serverStatusWindowManager = ServerStatusWindowManager()

    @State private var hostSearchQuery = ""
    @State private var selectedHostID: UUID?
    @State private var selectedTemplateID: UUID?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var isFilePanelVisible = false
    @State private var collapsedGroupNames: Set<String> = []
    @State private var isGroupEditorSheetPresented = false
    @State private var groupEditorMode: SidebarGroupEditorMode = .create
    @State private var groupEditorSourceName = ""
    @State private var groupEditorDraft = ""
    @State private var isHostEditorSheetPresented = false
    @State private var hostEditorMode: SidebarHostEditorMode = .create
    @State private var hostEditorDraft = SidebarHostEditorDraft()
    @State private var hostEditorTestState: HostConnectionTestState = .idle
    @State private var isPasswordSaveConsentAlertPresented = false
    @State private var isExportSheetPresented = false
    @State private var exportDraft = HostExportDraft()
    @State private var isPasswordExportWarningPresented = false
    @State private var isConnectionInfoPasswordWarningPresented = false
    @State private var pendingConnectionInfoPasswordCopyHost: RemoraCore.Host?
    @State private var isExportingHosts = false
    @State private var isImportingHosts = false
    @State private var isImportSourceSheetPresented = false
    @State private var isExportResultAlertPresented = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage = ""
    @State private var isImportProgressSheetPresented = false
    @State private var importSource = HostConnectionImportSource.remoraJSONCSV
    @State private var importSourceFilename = ""
    @State private var importProgress = HostConnectionImportProgress(phase: tr("Preparing"), completed: 0, total: 1)
    @State private var importResultMessage: String?
    @State private var importErrorMessage: String?
    @State private var isRenameSessionSheetPresented = false
    @State private var renameSessionID: UUID?
    @State private var renameSessionDraft = ""
    @State private var quickCommandEditorHostID: UUID?
    @State private var quickCommandEditingID: UUID?
    @State private var quickCommandNameDraft = ""
    @State private var quickCommandBodyDraft = ""
    @State private var quickCommandValidationMessage: String?
    @State private var quickPathEditorHostID: UUID?
    @State private var quickPathEditingID: UUID?
    @State private var quickPathNameDraft = ""
    @State private var quickPathValueDraft = ""
    @State private var quickPathValidationMessage: String?
    @State private var fileManagerSFTPBindingKey = "disconnected"
    @State private var fileManagerSFTPBootstrapTask: Task<Void, Never>?
    @AppStorage(AppSettings.passwordSaveConsentAcknowledgedKey)
    private var hasAcknowledgedPasswordSaveConsent = false
    @AppStorage(AppSettings.connectionInfoPasswordCopyMuteUntilKey)
    private var connectionInfoPasswordCopyMutedUntilEpoch = 0.0
    @AppStorage(AppSettings.connectionInfoPasswordCopyMuteForeverKey)
    private var connectionInfoPasswordCopyMuteForever = false
    @AppStorage(AppSettings.serverMetricsActiveRefreshSecondsKey)
    private var serverMetricsActiveRefreshSeconds = AppSettings.defaultServerMetricsActiveRefreshSeconds
    @AppStorage(AppSettings.serverMetricsInactiveRefreshSecondsKey)
    private var serverMetricsInactiveRefreshSeconds = AppSettings.defaultServerMetricsInactiveRefreshSeconds
    @AppStorage(AppSettings.serverMetricsMaxConcurrentFetchesKey)
    private var serverMetricsMaxConcurrentFetches = AppSettings.defaultServerMetricsMaxConcurrentFetches
    private let serverMetricsTrackingTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var selectedHost: RemoraCore.Host? {
        hostCatalog.host(id: selectedHostID)
    }

    private var connectionInfoPasswordCopyMutedUntil: Date? {
        guard connectionInfoPasswordCopyMutedUntilEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: connectionInfoPasswordCopyMutedUntilEpoch)
    }

    private var quickCommandEditorHost: RemoraCore.Host? {
        hostCatalog.host(id: quickCommandEditorHostID)
    }

    private var quickPathEditorHost: RemoraCore.Host? {
        hostCatalog.host(id: quickPathEditorHostID)
    }

    private var quickCommandEditorBinding: Binding<Bool> {
        Binding(
            get: { quickCommandEditorHostID != nil },
            set: { isPresented in
                if !isPresented {
                    dismissQuickCommandEditor()
                }
            }
        )
    }

    private var quickPathEditorBinding: Binding<Bool> {
        Binding(
            get: { quickPathEditorHostID != nil },
            set: { isPresented in
                if !isPresented {
                    dismissQuickPathEditor()
                }
            }
        )
    }

    private var availableTemplates: [HostSessionTemplate] {
        hostCatalog.templates(for: selectedHostID)
    }

    private var selectedTemplate: HostSessionTemplate? {
        guard let selectedTemplateID else { return nil }
        return availableTemplates.first(where: { $0.id == selectedTemplateID })
    }

    private var visibleGroupSections: [HostGroupSection] {
        hostCatalog.groupSections(matching: hostSearchQuery)
    }

    private var activeRuntimeSFTPStatePublisher: AnyPublisher<ActiveRuntimeSFTPState, Never> {
        guard let runtime = workspace.activePane?.runtime else {
            return Just(
                ActiveRuntimeSFTPState(
                    runtimeID: nil,
                    connectionMode: nil,
                    connectionState: "Disconnected",
                    hostSignature: nil
                )
            )
            .eraseToAnyPublisher()
        }

        return Publishers.CombineLatest3(
            runtime.$connectionMode,
            runtime.$connectionState,
            runtime.$connectedSSHHost
        )
        .map { mode, state, host in
            ActiveRuntimeSFTPState(
                runtimeID: ObjectIdentifier(runtime),
                connectionMode: mode,
                connectionState: state,
                hostSignature: host.map(Self.sftpHostSignature(for:))
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    var body: some View {
        let rootContent = ZStack {
            backgroundGradient

            NavigationSplitView(columnVisibility: $splitVisibility) {
                sidebar
            } detail: {
                detailWorkspace
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 1200, minHeight: 760)

        let lifecycleContent = rootContent
            .onAppear {
                if selectedHostID == nil {
                    selectedHostID = hostCatalog.hosts.first?.id
                }
                if let firstPane = workspace.activePane {
                    firstPane.runtime.connectLocalShell()
                }
                directorySyncBridge.bind(fileTransfer: fileTransfer, runtime: workspace.activePane?.runtime)
                syncServerMetricsConfiguration()
                syncFileManagerSFTPBinding()
                syncServerMetricsTracking()
            }
            .onChange(of: selectedHostID) {
                selectedTemplateID = availableTemplates.first?.id
            }
            .onChange(of: workspace.activeTabID) {
                directorySyncBridge.attachRuntime(workspace.activePane?.runtime)
                syncFileManagerSFTPBinding()
                syncServerMetricsTracking()
            }
            .onChange(of: workspace.activePaneByTab) {
                directorySyncBridge.attachRuntime(workspace.activePane?.runtime)
                syncFileManagerSFTPBinding()
                syncServerMetricsTracking()
            }

        let commandContent = lifecycleContent
            .onReceive(NotificationCenter.default.publisher(for: .remoraOpenSettingsCommand)) { _ in
                openWindow(id: "settings")
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraToggleSidebarCommand)) { _ in
                toggleSSHSidebarVisibility()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraNewSSHConnectionCommand)) { _ in
                beginCreateHostInPreferredGroup()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraImportConnectionsCommand)) { _ in
                guard !isExportingHosts, !isImportingHosts, !hostCatalog.isLoading else { return }
                beginImportHosts()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraExportConnectionsCommand)) { _ in
                guard !isExportingHosts, !isImportingHosts, !hostCatalog.isLoading else { return }
                beginExportAllHosts()
            }

        let syncedContent = commandContent
            .onReceive(activeRuntimeSFTPStatePublisher) { _ in
                syncFileManagerSFTPBinding()
                syncServerMetricsTracking()
            }
            .onReceive(serverMetricsTrackingTimer) { _ in
                syncServerMetricsTracking()
            }
            .onChange(of: hostCatalog.hosts) {
                if let selectedHostID, hostCatalog.host(id: selectedHostID) != nil {
                    return
                }
                selectedHostID = hostCatalog.hosts.first?.id
                selectedTemplateID = availableTemplates.first?.id
            }
            .onChange(of: hostCatalog.groups) {
                collapsedGroupNames = collapsedGroupNames.intersection(Set(hostCatalog.groups))
            }
            .onChange(of: serverMetricsActiveRefreshSeconds) {
                syncServerMetricsConfiguration()
            }
            .onChange(of: serverMetricsInactiveRefreshSeconds) {
                syncServerMetricsConfiguration()
            }
            .onChange(of: serverMetricsMaxConcurrentFetches) {
                syncServerMetricsConfiguration()
            }

        return syncedContent
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: workspace.activeTabID)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: isFilePanelVisible)
    }

    private var backgroundGradient: some View {
        VisualStyle.rightPanelBackground
            .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarActionRowButton(
                title: tr("New SSH Connection"),
                systemImage: "plus"
            ) {
                beginCreateHostInPreferredGroup()
            }
            .accessibilityIdentifier("sidebar-new-ssh-connection")
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)

            SidebarActionRowButton(
                title: isExportingHosts ? tr("Exporting...") : tr("Export Connections"),
                systemImage: "square.and.arrow.up"
            ) {
                beginExportAllHosts()
            }
            .disabled(isExportingHosts || isImportingHosts || hostCatalog.isLoading)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            SidebarActionRowButton(
                title: isImportingHosts ? tr("Importing...") : tr("Import Connections"),
                systemImage: "square.and.arrow.down"
            ) {
                beginImportHosts()
            }
            .accessibilityIdentifier("sidebar-import-connections")
            .disabled(isExportingHosts || isImportingHosts || hostCatalog.isLoading)
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            TextField(tr("Search SSH host"), text: $hostSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(VisualStyle.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VisualStyle.inputFieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(VisualStyle.borderSoft, lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Text(tr("SSH Threads"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)
                Spacer()
                SidebarIconButton(systemImage: "folder.badge.plus") {
                    beginCreateGroup()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            ScrollView {
                if hostCatalog.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(tr("Loading SSH connections..."))
                            .font(.system(size: 12))
                            .foregroundStyle(VisualStyle.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .accessibilityIdentifier("sidebar-hosts-loading")
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                } else if hostCatalog.hosts.isEmpty {
                    sidebarEmptyState
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleGroupSections) { section in
                            SidebarGroupSectionView(
                                section: section,
                                selectedHostID: selectedHostID,
                                isCollapsed: collapsedGroupNames.contains(section.name),
                                onToggleCollapsed: {
                                    toggleGroupCollapse(section.name)
                                },
                                onAddThread: {
                                    beginCreateHost(in: section.name)
                                },
                                onEditGroup: {
                                    beginEditGroup(section.name)
                                },
                                onExportGroup: {
                                    beginExportGroup(section.name)
                                },
                                onDeleteGroup: {
                                    deleteGroup(section.name)
                                },
                                onSelectThread: { hostID in
                                    selectedHostID = hostID
                                },
                                onOpenThread: { hostID in
                                    openHostInNewSession(hostID)
                                },
                                onEditThread: { hostID in
                                    beginEditHost(hostID)
                                },
                                onCopyConnectionInfo: { host in
                                    copyConnectionInfo(host)
                                },
                                onCopyAddress: { host in
                                    copyToPasteboard(host.address)
                                },
                                onCopySSHCommand: { host in
                                    copyToPasteboard(HostConnectionClipboardBuilder.sshCommand(for: host))
                                },
                                onManageQuickCommands: { hostID in
                                    beginManageQuickCommands(for: hostID)
                                },
                                onDeleteThread: { hostID in
                                    deleteHost(hostID)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                SidebarActionRowButton(
                    title: tr("Settings"),
                    systemImage: "gearshape"
                ) {
                    openWindow(id: "settings")
                }
                .accessibilityIdentifier("sidebar-settings")

                SidebarMenuIconButton(systemImage: "questionmark.circle") {
                    Button(tr("View on GitHub")) {
                        openURL(AppLinks.repositoryURL)
                    }
                    Button(tr("Report an issue")) {
                        openURL(AppLinks.issuesURL)
                    }
                }
                .help(tr("Help & Community"))
                .accessibilityIdentifier("sidebar-help-community")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .background(VisualStyle.leftSidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(VisualStyle.borderSoft)
                .frame(width: 1)
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 340)
        .alert(exportAlertTitle, isPresented: $isExportResultAlertPresented) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
        .alert(tr("Save password in Keychain?"), isPresented: $isPasswordSaveConsentAlertPresented) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Save to Keychain")) {
                hasAcknowledgedPasswordSaveConsent = true
                hostEditorDraft.savePassword = true
            }
        } message: {
            Text(tr("Remora stores saved passwords only in your macOS Keychain for SSH/SFTP authentication. They are not uploaded or used for anything else unless you explicitly choose to export them."))
        }
        .alert(tr("Include saved passwords in export?"), isPresented: $isPasswordExportWarningPresented) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Export with Passwords"), role: .destructive) {
                startExport(with: exportDraft)
            }
        } message: {
            Text(tr("Saved passwords will be written to the export file in plaintext. Only continue if you understand the risk and control where the file will be stored."))
        }
        .alert(tr("Copy saved SSH password?"), isPresented: $isConnectionInfoPasswordWarningPresented) {
            Button(tr("Cancel"), role: .cancel) {
                pendingConnectionInfoPasswordCopyHost = nil
            }
            Button(tr("Continue Once")) {
                applyConnectionInfoPasswordCopyChoice(.continueOnce)
            }
            Button(tr("Don't Remind Again Today")) {
                applyConnectionInfoPasswordCopyChoice(.dontRemindAgainToday)
            }
            Button(tr("Don't Remind Again")) {
                applyConnectionInfoPasswordCopyChoice(.dontRemindAgainEver)
            }
        } message: {
            Text(tr("This will place the saved SSH password on the macOS clipboard in plaintext. Other apps, clipboard managers, or sync services may be able to read it."))
        }
        .sheet(isPresented: $isGroupEditorSheetPresented) {
            SidebarGroupEditorSheet(
                mode: groupEditorMode,
                value: $groupEditorDraft,
                onCancel: {
                    isGroupEditorSheetPresented = false
                },
                onConfirm: {
                    commitGroupEditor()
                }
            )
        }
        .sheet(isPresented: $isExportSheetPresented) {
            HostExportSheet(
                draft: $exportDraft,
                isExporting: isExportingHosts,
                onCancel: {
                    isExportSheetPresented = false
                },
                onConfirm: {
                    isExportSheetPresented = false
                    if exportDraft.includeSavedPasswords {
                        isPasswordExportWarningPresented = true
                    } else {
                        startExport(with: exportDraft)
                    }
                }
            )
        }
        .sheet(isPresented: $isHostEditorSheetPresented) {
            SidebarHostEditorSheet(
                mode: hostEditorMode,
                draft: $hostEditorDraft,
                testState: hostEditorTestState,
                onCancel: {
                    isHostEditorSheetPresented = false
                },
                onPasswordSaveChange: handlePasswordSaveToggleChange,
                onTestConnection: {
                    testHostConnection()
                },
                onConfirm: {
                    Task {
                        await commitHostEditor()
                    }
                }
            )
        }
        .sheet(isPresented: $isRenameSessionSheetPresented) {
            SidebarRenameSheet(
                title: tr("Rename Session"),
                fieldTitle: tr("Session title"),
                value: $renameSessionDraft,
                onCancel: {
                    isRenameSessionSheetPresented = false
                },
                onConfirm: {
                    commitRenameSession()
                }
            )
        }
        .sheet(isPresented: quickCommandEditorBinding) {
            quickCommandManagerSheet
        }
        .sheet(isPresented: quickPathEditorBinding) {
            quickPathManagerSheet
        }
        .sheet(isPresented: $isImportSourceSheetPresented) {
            importSourceSheet
        }
        .sheet(isPresented: $isImportProgressSheetPresented) {
            importProgressSheet
                .interactiveDismissDisabled(isImportingHosts)
        }
    }

    private var detailWorkspace: some View {
        VStack(spacing: VisualStyle.panelSpacing) {
            sessionContainer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !workspace.tabs.isEmpty, shouldShowFileManager {
                fileManagerDisclosure
            }
        }
        .padding(VisualStyle.pagePadding)
    }

    private var shouldShowFileManager: Bool {
        workspace.activePane?.runtime.connectionMode == .ssh
    }

    private var sessionContainer: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                sessionTabBar
                Divider()
                    .overlay(VisualStyle.borderSoft)
            }
            Group {
                if workspace.tabs.isEmpty {
                    emptySessionPlaceholder
                } else {
                    ZStack {
                        ForEach(workspace.tabs) { tab in
                            let isActive = workspace.activeTabID == tab.id
                            sessionContent(for: tab)
                                .opacity(isActive ? 1 : 0)
                                .allowsHitTesting(isActive)
                                .accessibilityHidden(!isActive)
                                .zIndex(isActive ? 1 : 0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassCard(fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft, showsShadow: false)
    }

    private var emptySessionPlaceholder: some View {
        VStack(spacing: 14) {
            Group {
                if let appIconImage = Self.resolveWelcomeAppIconImage() {
                    Image(nsImage: appIconImage)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                        .resizable()
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(VisualStyle.textSecondary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(tr("Welcome to Remora"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Text(tr("Create an SSH connection to start your first session."))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(VisualStyle.textSecondary)

            HStack(spacing: 10) {
                Button(tr("New SSH Connection")) {
                    beginCreateHostInPreferredGroup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("session-placeholder-new-ssh")

                Button(tr("Open Local Session")) {
                    workspace.createTab()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("session-placeholder-open-local")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func resolveWelcomeAppIconImage() -> NSImage? {
        if NSApp.applicationIconImage.size.width > 0 {
            return NSApp.applicationIconImage
        }

        let fileManager = FileManager.default
        var candidateDirectories: [URL] = []

        candidateDirectories.append(URL(fileURLWithPath: fileManager.currentDirectoryPath))

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidateDirectories.append(sourceRoot)

        if let executableURL = Bundle.main.executableURL {
            var directory = executableURL.deletingLastPathComponent()
            for _ in 0 ..< 8 {
                candidateDirectories.append(directory)
                directory.deleteLastPathComponent()
            }
        }

        var visitedPaths: Set<String> = []
        for directory in candidateDirectories {
            let standardizedPath = directory.standardizedFileURL.path
            guard !visitedPaths.contains(standardizedPath) else { continue }
            visitedPaths.insert(standardizedPath)

            let iconCandidates = [
                // Brand logo for welcome placeholder.
                directory.appendingPathComponent("logo.png"),
            ]

            for candidate in iconCandidates where fileManager.fileExists(atPath: candidate.path) {
                if let image = NSImage(contentsOf: candidate) {
                    image.isTemplate = false
                    return image
                }
            }
        }

        return nil
    }

    private var sessionTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs) { tab in
                    if let runtime = runtimeForTab(tab) {
                        SessionTabBarItem(
                            title: tab.title,
                            runtime: runtime,
                            metricsState: serverMetricsCenter.state(for: runtime.connectedSSHHost),
                            isActive: workspace.activeTabID == tab.id,
                            canClose: workspace.tabs.count > 1,
                            onSelect: {
                                workspace.selectTab(tab.id)
                            },
                            onOpenMetricsWindow: {
                                guard let host = runtime.connectedSSHHost else { return }
                                openServerStatusWindow(for: host, runtime: runtime)
                            },
                            onClose: {
                                workspace.closeTab(tab.id)
                            }
                        )
                        .contextMenu {
                            sessionContextMenu(for: tab)
                        }
                    }
                }

                Button {
                    workspace.createTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session-tab-add")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VisualStyle.rightPanelBackground)
    }

    @ViewBuilder
    private func sessionContextMenu(for tab: TerminalTabModel) -> some View {
        let tabIndex = workspace.tabs.firstIndex(where: { $0.id == tab.id })
        let hasTabsOnLeft = tabIndex.map { $0 > 0 } ?? false
        let hasTabsOnRight = tabIndex.map { $0 + 1 < workspace.tabs.count } ?? false
        let canCloseInactiveTabs: Bool = {
            guard let activeTabID = workspace.activeTabID else { return false }
            return workspace.tabs.contains { $0.id != activeTabID }
        }()

        Button(tr("New Session")) {
            workspace.createTab()
        }

        Button(tr("Rename Session")) {
            beginRenameSession(tab.id)
        }

        Divider()

        Button(tr("Close Current Session"), role: .destructive) {
            workspace.closeTab(tab.id)
        }

        Button(tr("Close All Sessions"), role: .destructive) {
            workspace.closeAllTabs()
        }

        Button(tr("Close All Non-Active Sessions"), role: .destructive) {
            workspace.closeAllInactiveTabs()
        }
        .disabled(!canCloseInactiveTabs)

        Button(tr("Close Sessions to the Left"), role: .destructive) {
            workspace.closeTabsLeft(of: tab.id)
        }
        .disabled(!hasTabsOnLeft)

        Button(tr("Close Sessions to the Right"), role: .destructive) {
            workspace.closeTabsRight(of: tab.id)
        }
        .disabled(!hasTabsOnRight)

        Divider()

        Button(tr("Split Horizontal")) {
            workspace.selectTab(tab.id)
            workspace.splitActiveTab(orientation: .horizontal)
        }
        .disabled(tab.panes.count > 1)

        Button(tr("Split Vertical")) {
            workspace.selectTab(tab.id)
            workspace.splitActiveTab(orientation: .vertical)
        }
        .disabled(tab.panes.count > 1)

        if selectedHost != nil {
            Divider()
            Button(tr("Connect Selected SSH Host")) {
                connectSelectedHost(to: tab.id)
            }
            Button(tr("Disconnect Session")) {
                disconnectSession(tab.id)
            }
        }
    }

    @ViewBuilder
    private func sessionContent(for tab: TerminalTabModel) -> some View {
        if tab.panes.count == 1, let pane = tab.panes.first {
            paneView(pane, tabID: tab.id)
        } else if tab.panes.count == 2 {
            if tab.splitOrientation == .horizontal {
                HSplitView {
                    paneView(tab.panes[0], tabID: tab.id)
                    paneView(tab.panes[1], tabID: tab.id)
                }
            } else {
                VSplitView {
                    paneView(tab.panes[0], tabID: tab.id)
                    paneView(tab.panes[1], tabID: tab.id)
                }
            }
        } else {
            ContentUnavailableView(
                tr("Invalid Session State"),
                systemImage: "exclamationmark.triangle",
                description: Text(tr("Session pane count is not supported."))
            )
        }
    }

    private var fileManagerDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isFilePanelVisible.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isFilePanelVisible ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VisualStyle.textSecondary)
                    Label(tr("File Manager"), systemImage: "folder")
                        .panelTitleStyle()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isFilePanelVisible {
                Divider()
                    .overlay(VisualStyle.borderSoft)
                    .padding(.top, 2)
                let fileManagerHostID = workspace.activePane?.runtime.reconnectableSSHHost?.id
                FileManagerPanelView(
                    viewModel: fileTransfer,
                    quickPaths: hostCatalog.quickPaths(for: fileManagerHostID),
                    onRunQuickPath: { quickPath in
                        runQuickPath(quickPath)
                    },
                    onManageQuickPaths: {
                        guard let fileManagerHostID else { return }
                        beginManageQuickPaths(for: fileManagerHostID)
                    },
                    onAddCurrentQuickPath: { currentPath in
                        guard let fileManagerHostID else { return }
                        addCurrentPathToQuickPaths(currentPath, hostID: fileManagerHostID)
                    },
                    onEditDownloadPath: {
                        openSettingsAndFocusDownloadPath()
                    }
                )
                    .frame(minHeight: 280, maxHeight: 420, alignment: .top)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft, showsShadow: false)
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(VisualStyle.textTertiary)

            Text(tr("No SSH connections yet"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)

            Text(tr("Click \"New SSH Connection\" to create your first connection."))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(VisualStyle.textTertiary)

            Button(tr("New SSH Connection")) {
                beginCreateHostInPreferredGroup()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 10)
    }

    private func paneView(_ pane: TerminalPaneModel, tabID: UUID) -> some View {
        let hostID = pane.runtime.reconnectableSSHHost?.id
        return TerminalPaneView(
            pane: pane,
            quickCommands: hostCatalog.quickCommands(for: hostID),
            isFocused: workspace.activePaneByTab[tabID] == pane.id,
            onSelect: {
                workspace.selectPane(pane.id, in: tabID)
            },
            onRunQuickCommand: { quickCommand in
                runQuickCommand(quickCommand, in: pane.runtime)
            },
            onManageQuickCommands: {
                guard let hostID else { return }
                beginManageQuickCommands(for: hostID)
            }
        )
        .id(pane.id)
    }

    @ViewBuilder
    private var quickCommandManagerSheet: some View {
        if let host = quickCommandEditorHost {
            HostQuickCommandEditorSheet(
                host: host,
                commands: hostCatalog.quickCommands(for: host.id),
                editingCommandID: quickCommandEditingID,
                nameDraft: $quickCommandNameDraft,
                commandDraft: $quickCommandBodyDraft,
                validationMessage: quickCommandValidationMessage,
                onClose: {
                    dismissQuickCommandEditor()
                },
                onSave: {
                    commitQuickCommandDraft()
                },
                onStartEdit: { quickCommand in
                    beginEditQuickCommand(quickCommand)
                },
                onDelete: { quickCommandID in
                    deleteQuickCommand(quickCommandID, hostID: host.id)
                },
                onCancelEdit: {
                    resetQuickCommandDraft()
                }
            )
        } else {
            VStack(spacing: 12) {
                Text(tr("No SSH host selected."))
                    .font(.system(size: 13))
                    .foregroundStyle(VisualStyle.textSecondary)
                Button(tr("Close")) {
                    dismissQuickCommandEditor()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .frame(width: 460, height: 220)
        }
    }

    @ViewBuilder
    private var quickPathManagerSheet: some View {
        if let host = quickPathEditorHost {
            HostQuickPathEditorSheet(
                host: host,
                quickPaths: hostCatalog.quickPaths(for: host.id),
                editingPathID: quickPathEditingID,
                nameDraft: $quickPathNameDraft,
                pathDraft: $quickPathValueDraft,
                validationMessage: quickPathValidationMessage,
                onClose: {
                    dismissQuickPathEditor()
                },
                onSave: {
                    commitQuickPathDraft()
                },
                onStartEdit: { quickPath in
                    beginEditQuickPath(quickPath)
                },
                onDelete: { quickPathID in
                    deleteQuickPath(quickPathID, hostID: host.id)
                },
                onCancelEdit: {
                    resetQuickPathDraft()
                }
            )
        } else {
            VStack(spacing: 12) {
                Text(tr("No SSH host selected."))
                    .font(.system(size: 13))
                    .foregroundStyle(VisualStyle.textSecondary)
                Button(tr("Close")) {
                    dismissQuickPathEditor()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .frame(width: 460, height: 220)
        }
    }

    private func runtimeForTab(_ tab: TerminalTabModel) -> TerminalRuntime? {
        let preferredPaneID = workspace.activePaneByTab[tab.id]
        if let preferredPaneID,
           let preferredPane = tab.panes.first(where: { $0.id == preferredPaneID })
        {
            return preferredPane.runtime
        }
        return tab.panes.first?.runtime
    }

    private func toggleGroupCollapse(_ groupName: String) {
        if collapsedGroupNames.contains(groupName) {
            collapsedGroupNames.remove(groupName)
        } else {
            collapsedGroupNames.insert(groupName)
        }
    }

    private func toggleSSHSidebarVisibility() {
        splitVisibility = splitVisibility == .detailOnly ? .all : .detailOnly
    }

    private func beginCreateHostInPreferredGroup() {
        let preferredGroup = selectedHost?.group ?? hostCatalog.groups.first ?? "New Group"
        beginCreateHost(in: preferredGroup)
    }

    private func beginCreateHost(in groupName: String) {
        hostEditorMode = .create
        hostEditorDraft = SidebarHostEditorDraft(preferredGroup: groupName)
        hostEditorTestState = .idle
        isHostEditorSheetPresented = true
    }

    private func beginEditHost(_ hostID: UUID) {
        guard let host = hostCatalog.host(id: hostID) else { return }
        hostEditorMode = .edit(hostID)
        hostEditorDraft = SidebarHostEditorDraft(host: host)
        hostEditorTestState = .idle
        isHostEditorSheetPresented = true

        guard host.auth.method == .password,
              let passwordReference = host.auth.passwordReference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !passwordReference.isEmpty
        else {
            return
        }

        Task {
            let originalPassword = await CredentialStore().secret(for: passwordReference) ?? ""
            await MainActor.run {
                guard case .edit(let editingHostID) = hostEditorMode,
                      editingHostID == hostID,
                      isHostEditorSheetPresented
                else {
                    return
                }
                hostEditorDraft.password = originalPassword
            }
        }
    }

    @MainActor
    private func commitHostEditor() async {
        guard let host = await buildHostFromEditorDraft() else { return }

        let savedHost: RemoraCore.Host?
        switch hostEditorMode {
        case .create:
            savedHost = hostCatalog.addHost(host)
        case .edit:
            savedHost = hostCatalog.updateHost(host)
        }

        guard let savedHost else { return }
        collapsedGroupNames.remove(savedHost.group)
        selectedHostID = savedHost.id
        selectedTemplateID = nil
        hostEditorTestState = .idle
        isHostEditorSheetPresented = false
    }

    @MainActor
    private func buildHostFromEditorDraft() async -> RemoraCore.Host? {
        guard let port = hostEditorDraft.port else { return nil }

        let existingHost: RemoraCore.Host?
        switch hostEditorMode {
        case .create:
            existingHost = nil
        case .edit(let hostID):
            existingHost = hostCatalog.host(id: hostID)
        }

        let hostID = existingHost?.id ?? UUID()
        var host = existingHost ?? RemoraCore.Host(
            id: hostID,
            name: hostEditorDraft.name,
            address: hostEditorDraft.address,
            port: port,
            username: hostEditorDraft.username,
            group: hostEditorDraft.groupName,
            tags: ["new"],
            auth: HostAuth(method: .agent)
        )

        host.name = hostEditorDraft.name
        host.address = hostEditorDraft.address
        host.port = port
        host.username = hostEditorDraft.username
        host.group = hostEditorDraft.groupName

        let credentialStore = CredentialStore()
        let oldPasswordReference = existingHost?.auth.passwordReference
        let newPasswordValue = hostEditorDraft.password.trimmingCharacters(in: .whitespacesAndNewlines)
        var passwordReference: String?

        if hostEditorDraft.authMethod == .password {
            if hostEditorDraft.savePassword {
                if !newPasswordValue.isEmpty {
                    let key = oldPasswordReference ?? "host-password-\(hostID.uuidString)"
                    await credentialStore.setSecret(newPasswordValue, for: key)
                    passwordReference = key
                } else {
                    passwordReference = oldPasswordReference
                }
            } else {
                if let oldPasswordReference {
                    await credentialStore.removeSecret(for: oldPasswordReference)
                }
                passwordReference = nil
            }
        } else if let oldPasswordReference {
            await credentialStore.removeSecret(for: oldPasswordReference)
        }

        switch hostEditorDraft.authMethod {
        case .agent:
            host.auth = HostAuth(method: .agent)
        case .privateKey:
            let keyReference = hostEditorDraft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            host.auth = HostAuth(
                method: .privateKey,
                keyReference: keyReference.isEmpty ? nil : keyReference
            )
        case .password:
            host.auth = HostAuth(
                method: .password,
                passwordReference: passwordReference
            )
        }

        return host
    }

    private func testHostConnection() {
        guard let port = hostEditorDraft.port else {
            hostEditorTestState = .failure(tr("Port must be between 1 and 65535."))
            return
        }

        let address = hostEditorDraft.address
        guard !address.isEmpty else {
            hostEditorTestState = .failure(tr("Host cannot be empty."))
            return
        }

        hostEditorTestState = .testing
        Task {
            let result = await HostConnectionTester.testTCPReachability(host: address, port: port, timeout: 5)
            await MainActor.run {
                hostEditorTestState = result
            }
        }
    }

    private func handlePasswordSaveToggleChange(_ requestedEnabled: Bool) {
        switch PasswordSaveConsentGate.decision(
            currentlyEnabled: hostEditorDraft.savePassword,
            requestedEnabled: requestedEnabled,
            hasAcknowledgedWarning: hasAcknowledgedPasswordSaveConsent
        ) {
        case .apply(let value):
            hostEditorDraft.savePassword = value
        case .requireConsent:
            isPasswordSaveConsentAlertPresented = true
        }
    }

    private func beginCreateGroup() {
        groupEditorMode = .create
        groupEditorSourceName = ""
        groupEditorDraft = ""
        isGroupEditorSheetPresented = true
    }

    private func beginEditGroup(_ groupName: String) {
        groupEditorMode = .edit
        groupEditorSourceName = groupName
        groupEditorDraft = groupName
        isGroupEditorSheetPresented = true
    }

    private func commitGroupEditor() {
        let oldName = groupEditorSourceName
        let newName = groupEditorDraft
        isGroupEditorSheetPresented = false

        switch groupEditorMode {
        case .create:
            let finalName = hostCatalog.addGroup(named: newName)
            collapsedGroupNames.remove(finalName)
        case .edit:
            guard !oldName.isEmpty else { return }
            if let finalName = hostCatalog.renameGroup(from: oldName, to: newName),
               collapsedGroupNames.remove(oldName) != nil
            {
                collapsedGroupNames.insert(finalName)
            }
        }

        groupEditorSourceName = ""
        groupEditorDraft = ""
    }

    private func beginExportAllHosts() {
        guard !isExportingHosts else { return }
        exportDraft = HostExportDraft(scope: .all)
        isExportSheetPresented = true
    }

    private func beginExportGroup(_ groupName: String) {
        guard !isExportingHosts else { return }
        exportDraft = HostExportDraft(scope: .group(groupName))
        isExportSheetPresented = true
    }

    private func startExport(with draft: HostExportDraft) {
        let hosts = hostCatalog.hosts
        isExportingHosts = true

        Task {
            do {
                let outputURL = try await HostConnectionExporter.export(
                    hosts: hosts,
                    scope: draft.scope,
                    format: draft.format,
                    includeSavedPasswords: draft.includeSavedPasswords
                )
                await MainActor.run {
                    exportAlertTitle = tr("Export Complete")
                    exportAlertMessage = "\(tr("Saved to")) \(outputURL.path)"
                    isExportResultAlertPresented = true
                    isExportingHosts = false
                }
            } catch {
                await MainActor.run {
                    exportAlertTitle = tr("Export Failed")
                    exportAlertMessage = error.localizedDescription
                    isExportResultAlertPresented = true
                    isExportingHosts = false
                }
            }
        }
    }

    private func beginImportHosts() {
        guard !isImportingHosts else { return }
        isImportSourceSheetPresented = true
    }

    private func beginImportHosts(from source: HostConnectionImportSource) {
        guard source.isSupported, !isImportingHosts else { return }

        let panel = NSOpenPanel()
        panel.title = source.title
        panel.message = source.detail
        panel.prompt = tr("Import")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let directoryURL = source.defaultDirectoryURL,
           FileManager.default.fileExists(atPath: directoryURL.path)
        {
            panel.directoryURL = directoryURL
        }
        if let supportedExtensions = source.supportedFileExtensions {
            let contentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
            if !contentTypes.isEmpty {
                panel.allowedContentTypes = contentTypes
            }
        }

        if panel.runModal() == .OK, let url = panel.urls.first {
            startImport(from: url, source: source)
        }
    }

    private func selectImportSource(_ source: HostConnectionImportSource) {
        guard source.isSupported else { return }
        isImportSourceSheetPresented = false
        DispatchQueue.main.async {
            beginImportHosts(from: source)
        }
    }

    private func startImport(from fileURL: URL, source: HostConnectionImportSource) {
        guard !isImportingHosts else { return }
        isImportingHosts = true
        importSource = source
        importSourceFilename = fileURL.lastPathComponent
        importProgress = HostConnectionImportProgress(phase: tr("Preparing"), completed: 0, total: 1)
        importResultMessage = nil
        importErrorMessage = nil
        isImportProgressSheetPresented = true

        Task {
            do {
                let importedHosts = try await HostConnectionImporter.importConnections(
                    from: fileURL,
                    source: source,
                    progress: { progress in
                        Task { @MainActor in
                            importProgress = progress
                        }
                    }
                )

                let summary = await MainActor.run {
                    hostCatalog.importHosts(importedHosts)
                }

                await MainActor.run {
                    importProgress = HostConnectionImportProgress(
                        phase: tr("Completed"),
                        completed: max(summary.total, 1),
                        total: max(summary.total, 1)
                    )
                    importResultMessage = "\(tr("Imported")) \(summary.created) \(tr("new")), \(tr("updated")) \(summary.updated), \(tr("total")) \(summary.total)."
                    importErrorMessage = nil
                    isImportingHosts = false
                }
            } catch {
                await MainActor.run {
                    importErrorMessage = error.localizedDescription
                    importResultMessage = nil
                    isImportingHosts = false
                }
            }
        }
    }

    private func deleteGroup(_ groupName: String) {
        hostCatalog.deleteGroup(named: groupName)
        collapsedGroupNames.remove(groupName)
        if let selectedHostID, hostCatalog.host(id: selectedHostID) == nil {
            self.selectedHostID = nil
            selectedTemplateID = nil
        }
    }

    private func deleteHost(_ hostID: UUID) {
        hostCatalog.deleteHost(id: hostID)
        if selectedHostID == hostID {
            selectedHostID = nil
            selectedTemplateID = nil
        }
    }

    private func beginRenameSession(_ tabID: UUID) {
        guard let tab = workspace.tab(id: tabID) else { return }
        renameSessionID = tabID
        renameSessionDraft = tab.title
        isRenameSessionSheetPresented = true
    }

    private func commitRenameSession() {
        isRenameSessionSheetPresented = false
        guard let renameSessionID else { return }
        workspace.renameTab(renameSessionID, title: renameSessionDraft)
        self.renameSessionID = nil
    }

    private func beginManageQuickCommands(for hostID: UUID) {
        quickCommandEditorHostID = hostID
        resetQuickCommandDraft()
    }

    private func dismissQuickCommandEditor() {
        quickCommandEditorHostID = nil
        resetQuickCommandDraft()
    }

    private func resetQuickCommandDraft() {
        quickCommandEditingID = nil
        quickCommandNameDraft = ""
        quickCommandBodyDraft = ""
        quickCommandValidationMessage = nil
    }

    private func beginEditQuickCommand(_ quickCommand: HostQuickCommand) {
        quickCommandEditingID = quickCommand.id
        quickCommandNameDraft = quickCommand.name
        quickCommandBodyDraft = quickCommand.command
        quickCommandValidationMessage = nil
    }

    private func commitQuickCommandDraft() {
        guard let hostID = quickCommandEditorHostID else { return }
        let name = quickCommandNameDraft
        let command = quickCommandBodyDraft

        if let editingID = quickCommandEditingID {
            let updated = hostCatalog.updateQuickCommand(
                hostID: hostID,
                quickCommand: HostQuickCommand(id: editingID, name: name, command: command)
            )
            guard updated != nil else {
                quickCommandValidationMessage = tr("Command cannot be empty.")
                return
            }
        } else {
            let added = hostCatalog.addQuickCommand(hostID: hostID, name: name, command: command)
            guard added != nil else {
                quickCommandValidationMessage = tr("Command cannot be empty.")
                return
            }
        }

        resetQuickCommandDraft()
    }

    private func deleteQuickCommand(_ quickCommandID: UUID, hostID: UUID) {
        hostCatalog.deleteQuickCommand(hostID: hostID, quickCommandID: quickCommandID)
        if quickCommandEditingID == quickCommandID {
            resetQuickCommandDraft()
        }
    }

    private func runQuickCommand(_ quickCommand: HostQuickCommand, in runtime: TerminalRuntime) {
        let body = quickCommand.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        runtime.sendText("\(body)\n")
    }

    private func beginManageQuickPaths(for hostID: UUID) {
        quickPathEditorHostID = hostID
        resetQuickPathDraft()
    }

    private func dismissQuickPathEditor() {
        quickPathEditorHostID = nil
        resetQuickPathDraft()
    }

    private func resetQuickPathDraft() {
        quickPathEditingID = nil
        quickPathNameDraft = ""
        quickPathValueDraft = ""
        quickPathValidationMessage = nil
    }

    private func beginEditQuickPath(_ quickPath: HostQuickPath) {
        quickPathEditingID = quickPath.id
        quickPathNameDraft = quickPath.name
        quickPathValueDraft = quickPath.path
        quickPathValidationMessage = nil
    }

    private func commitQuickPathDraft() {
        guard let hostID = quickPathEditorHostID else { return }
        let name = quickPathNameDraft
        let path = quickPathValueDraft

        if let editingID = quickPathEditingID {
            let updated = hostCatalog.updateQuickPath(
                hostID: hostID,
                quickPath: HostQuickPath(id: editingID, name: name, path: path)
            )
            guard updated != nil else {
                quickPathValidationMessage = tr("Path cannot be empty.")
                return
            }
        } else {
            let added = hostCatalog.addQuickPath(hostID: hostID, name: name, path: path)
            guard added != nil else {
                quickPathValidationMessage = tr("Path cannot be empty.")
                return
            }
        }

        resetQuickPathDraft()
    }

    private func deleteQuickPath(_ quickPathID: UUID, hostID: UUID) {
        hostCatalog.deleteQuickPath(hostID: hostID, quickPathID: quickPathID)
        if quickPathEditingID == quickPathID {
            resetQuickPathDraft()
        }
    }

    private func runQuickPath(_ quickPath: HostQuickPath) {
        fileTransfer.navigateRemote(to: quickPath.path)
    }

    private func addCurrentPathToQuickPaths(_ currentPath: String, hostID: UUID) {
        let normalized = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let name = defaultQuickPathName(for: normalized)
        _ = hostCatalog.addQuickPath(hostID: hostID, name: name, path: normalized)
    }

    private func defaultQuickPathName(for path: String) -> String {
        if path == "/" { return tr("Root") }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return fileName.isEmpty ? path : fileName
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyConnectionInfo(_ host: RemoraCore.Host) {
        Task {
            let decision = await connectionInfoPasswordCopyDecision(for: host)
            await MainActor.run {
                switch decision {
                case .copy(let includePassword):
                    copyConnectionInfoToPasteboard(host, includePassword: includePassword)
                case .requireConfirmation:
                    pendingConnectionInfoPasswordCopyHost = host
                    isConnectionInfoPasswordWarningPresented = true
                }
            }
        }
    }

    private func connectionInfoPasswordCopyDecision(
        for host: RemoraCore.Host,
        now: Date = Date()
    ) async -> ConnectionInfoPasswordCopyConsentDecision {
        let includePasswordCandidate = await hasSavedPassword(for: host)
        return ConnectionInfoPasswordCopyConsentGate.decision(
            hostUsesPasswordAuth: includePasswordCandidate,
            mutedUntil: connectionInfoPasswordCopyMutedUntil,
            muteForever: connectionInfoPasswordCopyMuteForever,
            now: now
        )
    }

    private func hasSavedPassword(for host: RemoraCore.Host) async -> Bool {
        guard host.auth.method == .password,
              let passwordReference = host.auth.passwordReference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !passwordReference.isEmpty
        else {
            return false
        }

        let credentialStore = CredentialStore()
        guard let password = await credentialStore.secret(for: passwordReference) else {
            return false
        }
        return !password.isEmpty
    }

    private func copyConnectionInfoToPasteboard(_ host: RemoraCore.Host, includePassword: Bool) {
        Task {
            let text = await HostConnectionClipboardBuilder.connectionInfoText(
                for: host,
                includePassword: includePassword
            )
            await MainActor.run {
                copyToPasteboard(text)
            }
        }
    }

    private func applyConnectionInfoPasswordCopyChoice(_ choice: ConnectionInfoPasswordCopyConsentChoice) {
        guard let host = pendingConnectionInfoPasswordCopyHost else {
            isConnectionInfoPasswordWarningPresented = false
            return
        }

        let outcome = ConnectionInfoPasswordCopyConsentGate.outcome(for: choice)
        isConnectionInfoPasswordWarningPresented = false
        pendingConnectionInfoPasswordCopyHost = nil

        switch choice {
        case .cancel:
            return
        case .continueOnce:
            connectionInfoPasswordCopyMutedUntilEpoch = 0
            connectionInfoPasswordCopyMuteForever = false
        case .dontRemindAgainToday:
            connectionInfoPasswordCopyMutedUntilEpoch = outcome.mutedUntil?.timeIntervalSince1970 ?? 0
            connectionInfoPasswordCopyMuteForever = false
        case .dontRemindAgainEver:
            connectionInfoPasswordCopyMutedUntilEpoch = 0
            connectionInfoPasswordCopyMuteForever = true
        }

        guard outcome.shouldCopy else { return }
        copyConnectionInfoToPasteboard(host, includePassword: outcome.includePassword)
    }

    private func connectSelectedHost(to tabID: UUID) {
        guard let host = selectedHost else { return }
        workspace.selectTab(tabID)
        workspace.connectActivePane(host: host, template: selectedTemplate)
        bootstrapFileManagerBindingForActiveRuntime()
        hostCatalog.markConnected(hostID: host.id)
    }

    private func openHostInNewSession(_ hostID: UUID) {
        guard let host = hostCatalog.host(id: hostID) else { return }
        selectedHostID = hostID
        selectedTemplateID = nil
        workspace.createTab(title: host.name, connectLocalShell: false)
        guard let tabID = workspace.activeTabID else { return }
        workspace.selectTab(tabID)
        workspace.connectActivePane(host: host, template: nil)
        bootstrapFileManagerBindingForActiveRuntime()
        hostCatalog.markConnected(hostID: host.id)
    }

    private func disconnectSession(_ tabID: UUID) {
        workspace.selectTab(tabID)
        workspace.disconnectActivePane()
    }

    private func openSettingsAndFocusDownloadPath() {
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: .remoraOpenDownloadDirectorySetting, object: nil)
        }
    }

    private func syncServerMetricsTracking() {
        let connectedHosts = workspace.tabs.compactMap { tab in
            runtimeForTab(tab)?.connectedSSHHost
        }
        let activeHost = workspace.activePane?.runtime.connectedSSHHost
        serverMetricsCenter.updateTrackedHosts(connectedHosts, activeHost: activeHost)
    }

    private func syncServerMetricsConfiguration() {
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

        serverMetricsCenter.configure(
            activeRefreshInterval: TimeInterval(normalizedActive),
            inactiveRefreshInterval: TimeInterval(normalizedInactive),
            maxConcurrentFetches: normalizedConcurrent
        )
    }

    private func openServerStatusWindow(for host: RemoraCore.Host, runtime: TerminalRuntime) {
        serverStatusWindowManager.present(
            host: host,
            runtime: runtime,
            metricsCenter: serverMetricsCenter
        )
    }

    private func syncFileManagerSFTPBinding() {
        guard let activeTabID = workspace.activeTabID,
              let activePane = workspace.activePane
        else {
            bindDisconnectedSFTPIfNeeded(bindingKey: "tab:none|pane:none|disconnected")
            return
        }
        let runtime = activePane.runtime

        if runtime.connectionMode == .ssh, let host = runtime.connectedSSHHost {
            let bindingKey = Self.fileManagerBindingKey(
                tabID: activeTabID,
                paneID: activePane.id,
                host: host
            )
            guard fileManagerSFTPBindingKey != bindingKey else { return }
            fileManagerSFTPBindingKey = bindingKey
            fileTransfer.bindSFTPClient(
                SystemSFTPClient(host: host),
                bindingKey: bindingKey,
                initialRemoteDirectory: runtime.workingDirectory ?? "/"
            )
            return
        }

        // Keep current binding while SSH runtime is transitioning, then retry binding.
        if runtime.connectionMode == .ssh,
           runtime.connectionState == "Connecting"
            || runtime.connectionState.hasPrefix("Waiting")
            || runtime.connectionState.hasPrefix("Connected")
        {
            return
        }

        let disconnectedBindingKey = Self.fileManagerDisconnectedBindingKey(
            tabID: activeTabID,
            paneID: activePane.id
        )
        bindDisconnectedSFTPIfNeeded(bindingKey: disconnectedBindingKey)
    }

    private func bindDisconnectedSFTPIfNeeded(bindingKey: String) {
        guard fileManagerSFTPBindingKey != bindingKey else { return }
        fileManagerSFTPBindingKey = bindingKey
        fileTransfer.bindSFTPClient(
            DisconnectedSFTPClient(),
            bindingKey: bindingKey,
            initialRemoteDirectory: "/"
        )
    }

    private func bootstrapFileManagerBindingForActiveRuntime() {
        fileManagerSFTPBootstrapTask?.cancel()
        guard let runtime = workspace.activePane?.runtime else { return }
        let runtimeID = ObjectIdentifier(runtime)

        fileManagerSFTPBootstrapTask = Task {
            for _ in 0 ..< 160 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }

                let completed: Bool = await MainActor.run {
                    guard let currentRuntime = workspace.activePane?.runtime else { return true }
                    guard ObjectIdentifier(currentRuntime) == runtimeID else { return true }

                    syncFileManagerSFTPBinding()
                    return currentRuntime.connectionMode != .ssh || currentRuntime.connectedSSHHost != nil
                }

                if completed {
                    return
                }
            }
        }
    }

    private static func sftpHostSignature(for host: RemoraCore.Host) -> String {
        [
            host.id.uuidString,
            host.address,
            "\(host.port)",
            host.username,
            host.auth.method.rawValue,
            host.auth.keyReference ?? "",
            host.auth.passwordReference ?? "",
        ].joined(separator: "|")
    }

    private static func fileManagerBindingKey(tabID: UUID, paneID: UUID, host: RemoraCore.Host) -> String {
        "tab:\(tabID.uuidString)|pane:\(paneID.uuidString)|ssh:\(sftpHostSignature(for: host))"
    }

    private static func fileManagerDisconnectedBindingKey(tabID: UUID, paneID: UUID) -> String {
        "tab:\(tabID.uuidString)|pane:\(paneID.uuidString)|disconnected"
    }

    private var importSourceSheet: some View {
        HostImportSourceSheet(
            onCancel: {
                isImportSourceSheetPresented = false
            },
            onSelect: { source in
                selectImportSource(source)
            }
        )
    }

    private var importProgressSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Import SSH Connections"))
                .font(.headline)

            Text(importSource.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(VisualStyle.textSecondary)

            Text(importSourceFilename)
                .font(.caption.monospaced())
                .foregroundStyle(VisualStyle.textSecondary)
                .lineLimit(1)

            ProgressView(value: importProgress.fractionCompleted)
                .progressViewStyle(.linear)

            Text("\(min(importProgress.completed, importProgress.total))/\(max(importProgress.total, 1)) • \(importProgress.phase)")
                .font(.caption)
                .foregroundStyle(VisualStyle.textSecondary)

            if let importResultMessage {
                Text(importResultMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(tr("Close")) {
                    isImportProgressSheetPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImportingHosts)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

private struct HostImportSourceSheet: View {
    let onCancel: () -> Void
    let onSelect: (HostConnectionImportSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Choose Import Source"))
                .font(.headline)

            Text(tr("Select a format to import into Remora."))
                .font(.subheadline)
                .foregroundStyle(VisualStyle.textSecondary)

            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Supported Now"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VisualStyle.textSecondary)

                ForEach(HostConnectionImportSource.supportedCases) { source in
                    HostImportSourceRow(
                        source: source,
                        accessoryTitle: tr("Choose File"),
                        action: { onSelect(source) }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Coming Soon"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VisualStyle.textSecondary)

                ForEach(HostConnectionImportSource.upcomingCases) { source in
                    HostImportSourceRow(
                        source: source,
                        accessoryTitle: tr("Coming Soon"),
                        action: nil
                    )
                }
            }

            HStack {
                Spacer()
                Button(tr("Cancel")) {
                    onCancel()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct HostImportSourceRow: View {
    let source: HostConnectionImportSource
    let accessoryTitle: String
    let action: (() -> Void)?

    var body: some View {
        Button(action: {
            action?()
        }) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VisualStyle.textPrimary)

                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(VisualStyle.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                Text(accessoryTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(action == nil ? VisualStyle.textSecondary : VisualStyle.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(action == nil ? VisualStyle.mutedSurfaceBackground : VisualStyle.leftHoverBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .opacity(action == nil ? 0.8 : 1)
    }
}

private struct SidebarIconButton: View {
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? VisualStyle.leftHoverBackground : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct SidebarMenuIconButton<MenuContent: View>: View {
    let systemImage: String
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? VisualStyle.leftHoverBackground : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct SidebarActionRowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(VisualStyle.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovering ? VisualStyle.leftHoverBackground : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct SidebarGroupSectionView: View {
    let section: HostGroupSection
    let selectedHostID: UUID?
    let isCollapsed: Bool
    let onToggleCollapsed: () -> Void
    let onAddThread: () -> Void
    let onEditGroup: () -> Void
    let onExportGroup: () -> Void
    let onDeleteGroup: () -> Void
    let onSelectThread: (UUID) -> Void
    let onOpenThread: (UUID) -> Void
    let onEditThread: (UUID) -> Void
    let onCopyConnectionInfo: (RemoraCore.Host) -> Void
    let onCopyAddress: (RemoraCore.Host) -> Void
    let onCopySSHCommand: (RemoraCore.Host) -> Void
    let onManageQuickCommands: (UUID) -> Void
    let onDeleteThread: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: onToggleCollapsed) {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VisualStyle.textSecondary)
                        Text(section.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VisualStyle.textSecondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Text("\(section.hosts.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VisualStyle.textTertiary)

                SidebarIconButton(systemImage: "plus") {
                    onAddThread()
                }
                SidebarIconButton(systemImage: "trash") {
                    onDeleteGroup()
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 22)
            .contextMenu {
                Button(tr("Create connection")) {
                    onAddThread()
                }
                Button(isCollapsed ? tr("Expand group") : tr("Collapse group")) {
                    onToggleCollapsed()
                }
                Button(tr("Edit group")) {
                    onEditGroup()
                }
                Button(tr("Export group")) {
                    onExportGroup()
                }
                Divider()
                Button(tr("Delete group"), role: .destructive) {
                    onDeleteGroup()
                }
            }

            if !isCollapsed {
                if section.hosts.isEmpty {
                    Text(tr("No SSH threads"))
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ForEach(section.hosts) { host in
                        SidebarHostRow(
                            host: host,
                            isSelected: selectedHostID == host.id,
                            onSelect: {
                                onSelectThread(host.id)
                            },
                            onOpen: {
                                onOpenThread(host.id)
                            },
                            onEdit: {
                                onEditThread(host.id)
                            },
                            onCopyConnectionInfo: {
                                onCopyConnectionInfo(host)
                            },
                            onCopyAddress: {
                                onCopyAddress(host)
                            },
                            onCopySSHCommand: {
                                onCopySSHCommand(host)
                            },
                            onManageQuickCommands: {
                                onManageQuickCommands(host.id)
                            },
                            onDelete: {
                                onDeleteThread(host.id)
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct HostExportSheet: View {
    @Binding var draft: HostExportDraft
    let isExporting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Export SSH Connections"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Text(draft.scope.label)
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)

            Picker(tr("Format"), selection: $draft.format) {
                ForEach(HostExportFormat.allCases) { format in
                    Text(format == .json ? tr("Export as JSON") : tr("Export as CSV"))
                        .tag(format)
                }
            }
            .pickerStyle(.segmented)

            Toggle(tr("Include saved passwords (plaintext)"), isOn: $draft.includeSavedPasswords)
                .toggleStyle(.checkbox)

            if draft.includeSavedPasswords {
                Text(tr("Saved passwords will be written to the export file in plaintext. Only continue if you understand the risk and control where the file will be stored."))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                Button(tr("Export"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

private struct SidebarHostRow: View {
    let host: RemoraCore.Host
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onCopyConnectionInfo: () -> Void
    let onCopyAddress: () -> Void
    let onCopySSHCommand: () -> Void
    let onManageQuickCommands: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect()
            if NSApp.currentEvent?.clickCount == 2 {
                onOpen()
            }
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-host-row-\(host.name)")
        .animation(nil, value: isSelected)
        .contextMenu {
            Button(tr("Edit connection")) {
                onEdit()
            }
            Divider()
            Menu(tr("Copy")) {
                Button(tr("Copy connection info")) {
                    onCopyConnectionInfo()
                }
                Button(tr("Copy address")) {
                    onCopyAddress()
                }
                Button(tr("Copy SSH command")) {
                    onCopySSHCommand()
                }
            }
            Button(tr("Manage quick commands")) {
                onManageQuickCommands()
            }
            Divider()
            Button(tr("Delete connection"), role: .destructive) {
                onDelete()
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VisualStyle.textPrimary)
                    .lineLimit(1)
                Text(host.address)
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            if isHovering {
                HStack(spacing: 2) {
                    Button(action: onEdit) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(VisualStyle.textSecondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(VisualStyle.textSecondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                }
            } else if host.connectCount > 0 {
                Text("\(host.connectCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VisualStyle.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(VisualStyle.chipBackground))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? VisualStyle.borderStrong : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contentShape(Rectangle())
    }

    private var backgroundColor: Color {
        if isSelected { return VisualStyle.leftSelectedBackground }
        if isHovering { return VisualStyle.leftHoverBackground }
        return Color.clear
    }
}

private enum SidebarGroupEditorMode {
    case create
    case edit

    var title: String {
        switch self {
        case .create:
            return tr("New Thread Group")
        case .edit:
            return tr("Edit Thread Group")
        }
    }

    var confirmTitle: String {
        switch self {
        case .create:
            return tr("Create")
        case .edit:
            return tr("Save")
        }
    }
}

private enum SidebarHostEditorMode {
    case create
    case edit(UUID)

    var title: String {
        switch self {
        case .create:
            return tr("New SSH Connection")
        case .edit:
            return tr("Edit SSH Connection")
        }
    }

    var confirmTitle: String {
        switch self {
        case .create:
            return tr("Create")
        case .edit:
            return tr("Save")
        }
    }
}

private enum SidebarHostAuthMethod: String, CaseIterable, Identifiable {
    case agent = "SSH Agent"
    case privateKey = "Private Key"
    case password = "Password"

    var id: String { rawValue }
}

private struct SidebarHostEditorDraft {
    var connectionName: String
    var hostAddress: String
    var portText: String
    var usernameText: String
    var groupText: String
    var authMethod: SidebarHostAuthMethod
    var privateKeyPath: String
    var password: String
    var savePassword: Bool

    init(preferredGroup: String = "New Group") {
        self.connectionName = ""
        self.hostAddress = "127.0.0.1"
        self.portText = "22"
        self.usernameText = "root"
        self.groupText = preferredGroup
        self.authMethod = .password
        self.privateKeyPath = ""
        self.password = ""
        self.savePassword = false
    }

    init(host: RemoraCore.Host) {
        self.connectionName = host.name
        self.hostAddress = host.address
        self.portText = "\(host.port)"
        self.usernameText = host.username
        self.groupText = host.group
        self.privateKeyPath = host.auth.keyReference ?? ""
        self.password = ""
        self.savePassword = host.auth.passwordReference != nil

        switch host.auth.method {
        case .agent:
            self.authMethod = .agent
        case .privateKey:
            self.authMethod = .privateKey
        case .password:
            self.authMethod = .password
        }
    }

    var name: String {
        let trimmedName = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedAddress = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAddress.isEmpty ? "new-ssh" : trimmedAddress
    }

    var address: String {
        hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var username: String {
        let trimmed = usernameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "root" : trimmed
    }

    var groupName: String {
        let trimmed = groupText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Group" : trimmed
    }

    var port: Int? {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    var canSave: Bool {
        !address.isEmpty && port != nil
    }

    var canTestConnection: Bool {
        !address.isEmpty && port != nil
    }
}

private enum HostConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle, .testing:
            return nil
        case .success(let message), .failure(let message):
            return message
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return ""
        case .testing:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle:
            return VisualStyle.textTertiary
        case .testing:
            return VisualStyle.textSecondary
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}

private enum HostConnectionTester {
    static func testTCPReachability(host: String, port: Int, timeout: Int) async -> HostConnectionTestState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                process.arguments = ["-z", "-G", "\(max(1, timeout))", host, "\(port)"]

                let errorPipe = Pipe()
                process.standardOutput = Pipe()
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success("\(tr("Connection test passed")) (\(host):\(port))."))
                    } else if !errorText.isEmpty {
                        continuation.resume(returning: .failure(errorText))
                    } else {
                        continuation.resume(returning: .failure("\(tr("Cannot reach")) \(host):\(port)."))
                    }
                } catch {
                    continuation.resume(returning: .failure("\(tr("Connection test failed")): \(error.localizedDescription)"))
                }
            }
        }
    }
}

private struct SidebarGroupEditorSheet: View {
    let mode: SidebarGroupEditorMode
    @Binding var value: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            TextField(tr("Group name"), text: $value)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                Button(mode.confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct SidebarHostEditorSheet: View {
    let mode: SidebarHostEditorMode
    @Binding var draft: SidebarHostEditorDraft
    let testState: HostConnectionTestState
    let onCancel: () -> Void
    let onPasswordSaveChange: (Bool) -> Void
    let onTestConnection: () -> Void
    let onConfirm: () -> Void
    @State private var isPasswordVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
                .accessibilityIdentifier("host-editor-title")

            Group {
                TextField(tr("Connection name"), text: $draft.connectionName)
                TextField(tr("Host"), text: $draft.hostAddress)

                HStack(spacing: 10) {
                    TextField(tr("Port"), text: $draft.portText)
                        .frame(width: 90)
                    TextField(tr("Username"), text: $draft.usernameText)
                }

                TextField(tr("Group"), text: $draft.groupText)

                Picker(tr("Auth"), selection: $draft.authMethod) {
                    ForEach(SidebarHostAuthMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.menu)

                if draft.authMethod == .privateKey {
                    TextField(tr("Private key path"), text: $draft.privateKeyPath)
                }

                if draft.authMethod == .password {
                    HStack(spacing: 8) {
                        Group {
                            if isPasswordVisible {
                                TextField(tr("Password"), text: $draft.password)
                            } else {
                                SecureField(tr("Password"), text: $draft.password)
                            }
                        }

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(VisualStyle.textSecondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? tr("Hide password") : tr("Show password"))
                        .help(isPasswordVisible ? tr("Hide password") : tr("Show password"))
                    }
                    Toggle(
                        tr("Save password in Keychain"),
                        isOn: Binding(
                            get: { draft.savePassword },
                            set: { onPasswordSaveChange($0) }
                        )
                    )
                        .toggleStyle(.checkbox)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button(tr("Test Connection"), action: onTestConnection)
                    .disabled(!draft.canTestConnection || testState.isTesting)

                if testState.isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                if let message = testState.message {
                    Label(message, systemImage: testState.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(testState.color)
                }
            }

            HStack {
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                Button(mode.confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSave)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onChange(of: draft.authMethod) {
            if draft.authMethod != .password {
                isPasswordVisible = false
            }
        }
    }
}

private struct SidebarRenameSheet: View {
    let title: String
    let fieldTitle: String
    @Binding var value: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            TextField(fieldTitle, text: $value)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(tr("Cancel")) {
                    onCancel()
                }
                Button(tr("Save")) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct HostQuickCommandEditorSheet: View {
    let host: RemoraCore.Host
    let commands: [HostQuickCommand]
    let editingCommandID: UUID?
    @Binding var nameDraft: String
    @Binding var commandDraft: String
    let validationMessage: String?
    let onClose: () -> Void
    let onSave: () -> Void
    let onStartEdit: (HostQuickCommand) -> Void
    let onDelete: (UUID) -> Void
    let onCancelEdit: () -> Void

    private var isEditing: Bool {
        editingCommandID != nil
    }

    private var canSaveDraft: Bool {
        !commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(tr("Quick commands")) · \(host.name)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Group {
                if commands.isEmpty {
                    Text(tr("No quick commands yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VisualStyle.mutedSurfaceBackground)
                        )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(commands) { command in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(VisualStyle.textPrimary)
                                            .lineLimit(1)
                                        Text(command.command)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(VisualStyle.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    Button(tr("Edit")) {
                                        onStartEdit(command)
                                    }
                                    .buttonStyle(.borderless)

                                    Button(tr("Delete"), role: .destructive) {
                                        onDelete(command.id)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(VisualStyle.elevatedSurfaceBackground)
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 96, maxHeight: 220)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(isEditing ? tr("Edit command") : tr("New command"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)

                TextField(tr("Name"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)

                TextField(tr("Command"), text: $commandDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            HStack {
                if isEditing {
                    Button(tr("Cancel edit")) {
                        onCancelEdit()
                    }
                }
                Spacer()
                Button(tr("Close")) {
                    onClose()
                }
                Button(isEditing ? tr("Save") : tr("Add")) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveDraft)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

private struct HostQuickPathEditorSheet: View {
    let host: RemoraCore.Host
    let quickPaths: [HostQuickPath]
    let editingPathID: UUID?
    @Binding var nameDraft: String
    @Binding var pathDraft: String
    let validationMessage: String?
    let onClose: () -> Void
    let onSave: () -> Void
    let onStartEdit: (HostQuickPath) -> Void
    let onDelete: (UUID) -> Void
    let onCancelEdit: () -> Void

    private var isEditing: Bool {
        editingPathID != nil
    }

    private var canSaveDraft: Bool {
        !pathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(tr("Quick paths")) · \(host.name)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Group {
                if quickPaths.isEmpty {
                    Text(tr("No quick paths yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VisualStyle.mutedSurfaceBackground)
                        )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(quickPaths) { quickPath in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(quickPath.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(VisualStyle.textPrimary)
                                            .lineLimit(1)
                                        Text(quickPath.path)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(VisualStyle.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    Button(tr("Edit")) {
                                        onStartEdit(quickPath)
                                    }
                                    .buttonStyle(.borderless)

                                    Button(tr("Delete"), role: .destructive) {
                                        onDelete(quickPath.id)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(VisualStyle.elevatedSurfaceBackground)
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 96, maxHeight: 220)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(isEditing ? tr("Edit path") : tr("New path"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)

                TextField(tr("Name"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)

                TextField("/path/to/dir", text: $pathDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            HStack {
                if isEditing {
                    Button(tr("Cancel edit")) {
                        onCancelEdit()
                    }
                }
                Spacer()
                Button(tr("Close")) {
                    onClose()
                }
                Button(isEditing ? tr("Save") : tr("Add")) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveDraft)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

private struct SessionTabBarItem: View {
    let title: String
    @ObservedObject var runtime: TerminalRuntime
    let metricsState: ServerHostMetricsState?
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onOpenMetricsWindow: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false
    @State private var isMetricsPopoverPresented = false

    private var shouldShowMetrics: Bool {
        runtime.connectionMode == .ssh
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
                .disabled(runtime.connectedSSHHost == nil)
                .help(tr("Open server status window"))
                .onHover { hovering in
                    isMetricsPopoverPresented = hovering
                }
                .popover(isPresented: $isMetricsPopoverPresented, arrowEdge: .bottom) {
                    SessionMetricHoverCard(
                        hostTitle: hostDisplayTitle,
                        connectionState: localizedConnectionState(runtime.connectionState),
                        snapshot: metricsState?.snapshot,
                        isLoading: metricsState?.isLoading ?? false,
                        errorMessage: metricsState?.errorMessage
                    )
                    .padding(10)
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
            }
        }
    }
}

private struct SessionMetricCompactBars: View {
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

private struct SessionMetricHoverCard: View {
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
                    Text("\(tr("Memory")): \(formatByteValue(snapshot.memoryUsedBytes))/\(formatByteValue(snapshot.memoryTotalBytes))")
                    Text("\(tr("Disk")): \(formatByteValue(snapshot.diskUsedBytes))/\(formatByteValue(snapshot.diskTotalBytes))")
                    Text("\(tr("Sampled")): \(formatSampleTimestamp(snapshot.sampledAt))")
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
            Text(formatFractionAsPercent(fraction))
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

private func formatFractionAsPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
}

private func formatByteValue(_ bytes: Int64?) -> String {
    guard let bytes else { return "--" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .binary
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

private func formatSampleTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}
