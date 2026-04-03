import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import RemoraCore

extension ContentView {
    var backgroundGradient: some View {
        VisualStyle.rightPanelBackground
            .ignoresSafeArea()
    }

    var sidebar: some View {
        sidebarContent
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
            .alert(tr("Delete SSH connection?"), isPresented: isHostDeletionConfirmationPresented, presenting: pendingHostDeletion) { pending in
                Button(tr("Cancel"), role: .cancel) {
                    pendingHostDeletion = nil
                }
                Button(tr("Delete"), role: .destructive) {
                    confirmHostDeletion(pending)
                }
            } message: { pending in
                Text(
                    String(
                        format: tr("This will permanently remove \"%@\" (%@) from the SSH list."),
                        pending.name,
                        pending.address
                    )
                )
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
            .sheet(isPresented: groupDeletionSheetBinding) {
                if let pending = pendingGroupDeletion {
                    SidebarGroupDeletionSheet(
                        groupName: displayGroupName(pending.id),
                        hostCount: pending.hostCount,
                        deleteHosts: Binding(
                            get: { pendingGroupDeletion?.deleteHosts ?? false },
                            set: { newValue in
                                pendingGroupDeletion?.deleteHosts = newValue
                            }
                        ),
                        onCancel: {
                            self.pendingGroupDeletion = nil
                        },
                        onConfirm: {
                            guard let pendingGroupDeletion else { return }
                            confirmGroupDeletion(pendingGroupDeletion)
                        }
                    )
                }
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
                    hintText: tr("Only this tab name changes. The saved SSH connection name stays the same."),
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

    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            sidebarGroupsList
            Spacer(minLength: 8)
            sidebarFooter
        }
    }

    var sidebarHeader: some View {
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
                .focused($sidebarFocusedField, equals: .hostSearch)
                .accessibilityIdentifier("sidebar-host-search")
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

            SidebarThreadsHeaderView(
                actions: SidebarThreadsHeaderActions(
                    onCreateConnection: {
                        beginCreateHostInPreferredGroup()
                    },
                    onCreateGroup: {
                        beginCreateGroup()
                    }
                )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    var sidebarGroupsList: some View {
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
                    sidebarUngroupedHosts
                    ForEach(visibleGroupSections) { section in
                        sidebarGroupSection(section)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    var sidebarUngroupedHosts: some View {
        if !visibleUngroupedHosts.isEmpty {
            VStack(spacing: 4) {
                ForEach(visibleUngroupedHosts) { host in
                    SidebarHostRow(
                        host: host,
                        isSelected: selectedHostID == host.id,
                        dragPayload: SidebarDragPayload.host(host.id).rawValue,
                        onDropPayloads: { items in
                            handleDropPayloads(items, beforeHost: host)
                        },
                        onSelect: {
                            selectedHostID = host.id
                        },
                        onOpen: {
                            openHostInNewSession(host.id)
                        },
                        onEdit: {
                            beginEditHost(host.id)
                        },
                        onCopyConnectionInfo: {
                            copyConnectionInfo(host)
                        },
                        onCopyAddress: {
                            copyToPasteboard(host.address)
                        },
                        onCopySSHCommand: {
                            copyToPasteboard(HostConnectionClipboardBuilder.sshCommand(for: host))
                        },
                        onManageQuickCommands: {
                            beginManageQuickCommands(for: host.id)
                        },
                        onDelete: {
                            requestHostDeletion(host.id)
                        }
                    )
                }
            }
            .padding(.bottom, 4)
            .dropDestination(for: String.self) { items, _ in
                handleDropPayloadsIntoUngrouped(items)
            }
        } else {
            Text(tr("Drop here to keep this SSH connection ungrouped."))
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(VisualStyle.leftHoverBackground.opacity(0.35))
                )
                .dropDestination(for: String.self) { items, _ in
                    handleDropPayloadsIntoUngrouped(items)
                }
                .padding(.bottom, 4)
        }
    }

    var sidebarFooter: some View {
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

    var detailWorkspace: some View {
        Group {
            switch workspaceFocusMode {
            case .none:
                VStack(spacing: VisualStyle.panelSpacing) {
                    sessionContainer
                        .frame(maxWidth: .infinity, maxHeight: sessionShouldFillRemainingHeight ? .infinity : nil, alignment: .top)
                    if !workspace.tabs.isEmpty, shouldShowFileManager {
                        fileManagerDisclosure
                    }
                }

            case .terminal:
                focusedTerminalWorkspace

            case .fileManager:
                focusedFileManagerWorkspace
            }
        }
        .padding(VisualStyle.pagePadding)
    }

    @ViewBuilder
    func sidebarGroupSection(_ section: HostGroupSection) -> some View {
        SidebarGroupSectionView(
            section: section,
            displayName: displayGroupName(section.name),
            selectedHostID: selectedHostID,
            dragPayload: SidebarDragPayload.group(section.name).rawValue,
            onDropPayloads: { items in
                handleDropPayloads(items, intoGroup: section.name)
            },
            onDropBeforeHost: { items, host in
                handleDropPayloads(items, beforeHost: host)
            },
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
                requestHostDeletion(hostID)
            }
        )
    }

    var shouldShowFileManager: Bool {
        workspace.activePane?.runtime.connectionMode == .ssh
    }

    var normalizedBottomPanelVisibility: BottomPanelVisibilityState {
        var state = bottomPanelVisibility
        state.normalize(fileManagerAvailable: shouldShowFileManager)
        return state
    }

    var isTerminalPanelVisible: Bool {
        normalizedBottomPanelVisibility.terminal
    }

    var isFileManagerPanelVisible: Bool {
        normalizedBottomPanelVisibility.fileManager
    }

    var isTerminalFocusMode: Bool {
        workspaceFocusMode == .terminal
    }

    var isFileManagerFocusMode: Bool {
        workspaceFocusMode == .fileManager
    }

    var sessionShouldFillRemainingHeight: Bool {
        normalizedBottomPanelVisibility.sessionShouldFillRemainingHeight(fileManagerAvailable: shouldShowFileManager)
    }

    var fileManagerShouldFillRemainingHeight: Bool {
        normalizedBottomPanelVisibility.fileManagerShouldFillRemainingHeight(fileManagerAvailable: shouldShowFileManager)
    }

    var sessionContainer: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty, !isTerminalFocusMode {
                sessionTabBar
                Divider()
                    .overlay(VisualStyle.borderSoft)
            }
            Group {
                if workspace.tabs.isEmpty {
                    emptySessionPlaceholder
                } else if isTerminalFocusMode,
                          let activeTabID = workspace.activeTabID,
                          let activePane = workspace.activePane
                {
                    paneView(activePane, tabID: activeTabID)
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
            .frame(maxWidth: .infinity, maxHeight: sessionShouldFillRemainingHeight ? .infinity : nil, alignment: .top)
        }
        .glassCard(fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft, showsShadow: false)
        .layoutPriority(sessionShouldFillRemainingHeight ? 1 : 0)
        .coordinateSpace(name: "session-container")
        .overlayPreferenceValue(SessionMetricsButtonAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if let hoveredSessionMetricsTooltip,
                   let anchor = anchors[hoveredSessionMetricsTooltip.tabID]
                {
                    let frame = proxy[anchor]
                    SessionMetricsTooltip(
                        hostTitle: hoveredSessionMetricsTooltip.hostTitle,
                        connectionState: hoveredSessionMetricsTooltip.connectionState,
                        snapshot: hoveredSessionMetricsTooltip.snapshot,
                        isLoading: hoveredSessionMetricsTooltip.isLoading,
                        errorMessage: hoveredSessionMetricsTooltip.errorMessage
                    )
                    .background(
                        GeometryReader { tooltipProxy in
                            Color.clear
                                .onAppear {
                                    hoveredSessionMetricsTooltipSize = tooltipProxy.size
                                }
                                .onChange(of: tooltipProxy.size) { _, size in
                                    hoveredSessionMetricsTooltipSize = size
                                }
                        }
                    )
                    .offset(
                        x: SessionMetricsTooltipPlacement.xOffset(
                            anchorFrame: frame,
                            tooltipWidth: max(hoveredSessionMetricsTooltipSize.width, 1),
                            containerWidth: proxy.size.width
                        ),
                        y: frame.maxY + 8
                    )
                    .allowsHitTesting(false)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)),
                            removal: .opacity.combined(with: .scale(scale: 0.985, anchor: .topLeading))
                        )
                    )
                    .zIndex(100)
                }
            }
        }
        .animation(
            .easeOut(
                duration: hoveredSessionMetricsTooltip == nil
                    ? SessionMetricsTooltipStyle.exitDuration
                    : SessionMetricsTooltipStyle.enterDuration
            ),
            value: hoveredSessionMetricsTooltip != nil
        )
    }

    var emptySessionPlaceholder: some View {
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

    static func resolveWelcomeAppIconImage() -> NSImage? {
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

    var sessionTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs, id: \.id) { tab in
                    if let runtime = runtimeForTab(tab) {
                        SessionTabBarItem(
                            title: tab.title,
                            tabID: tab.id,
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
                            },
                            onMetricsHoverChange: { tooltip in
                                if let tooltip {
                                    hoveredSessionMetricsTooltip = tooltip
                                } else if hoveredSessionMetricsTooltip?.tabID == tab.id {
                                    hoveredSessionMetricsTooltip = nil
                                }
                            },
                            accessibilityIdentifier: "session-tab-\(tab.title)"
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
    func sessionContextMenu(for tab: TerminalTabModel) -> some View {
        let runtime = runtimeForTab(tab)
        let tabIndex = workspace.tabs.firstIndex(where: { $0.id == tab.id })
        let hasTabsOnLeft = tabIndex.map { $0 > 0 } ?? false
        let hasTabsOnRight = tabIndex.map { $0 + 1 < workspace.tabs.count } ?? false
        let canReconnectSSH = runtime?.reconnectableSSHHost != nil
        let canDisconnectSession = runtime != nil
        let renameHint = tr("Only this tab name changes. The saved SSH connection name stays the same.")
        let canCloseInactiveTabs: Bool = {
            guard let activeTabID = workspace.activeTabID else { return false }
            return workspace.tabs.contains { $0.id != activeTabID }
        }()

        contextMenuButton(tr("New Session"), systemImage: ContextMenuIconCatalog.newSession) {
            workspace.createTab()
        }

        contextMenuButton(tr("Rename Session"), systemImage: ContextMenuIconCatalog.rename) {
            beginRenameSession(tab.id)
        }
        .help(renameHint)

        contextMenuButton(tr("Split Horizontal"), systemImage: ContextMenuIconCatalog.splitHorizontal) {
            workspace.selectTab(tab.id)
            workspace.splitActiveTab(orientation: .horizontal)
        }
        .disabled(tab.panes.count > 1)

        contextMenuButton(tr("Split Vertical"), systemImage: ContextMenuIconCatalog.splitVertical) {
            workspace.selectTab(tab.id)
            workspace.splitActiveTab(orientation: .vertical)
        }
        .disabled(tab.panes.count > 1)

        if canReconnectSSH || canDisconnectSession {
            Divider()
            contextMenuButton(tr("Reconnect SSH"), systemImage: ContextMenuIconCatalog.reconnect) {
                reconnectSession(tab.id)
            }
            .disabled(!canReconnectSSH)

            contextMenuButton(tr("Disconnect Session"), systemImage: ContextMenuIconCatalog.disconnect) {
                disconnectSession(tab.id)
            }
            .disabled(!canDisconnectSession)
        }

        Divider()

        contextMenuButton(tr("Close Current Session"), systemImage: ContextMenuIconCatalog.closeCurrent, role: .destructive) {
            workspace.closeTab(tab.id)
        }

        contextMenuButton(tr("Close All Sessions"), systemImage: ContextMenuIconCatalog.closeAll, role: .destructive) {
            workspace.closeAllTabs()
        }

        contextMenuButton(tr("Close All Non-Active Sessions"), systemImage: ContextMenuIconCatalog.closeInactive, role: .destructive) {
            workspace.closeAllInactiveTabs()
        }
        .disabled(!canCloseInactiveTabs)

        contextMenuButton(tr("Close Sessions to the Left"), systemImage: ContextMenuIconCatalog.closeLeft, role: .destructive) {
            workspace.closeTabsLeft(of: tab.id)
        }
        .disabled(!hasTabsOnLeft)

        contextMenuButton(tr("Close Sessions to the Right"), systemImage: ContextMenuIconCatalog.closeRight, role: .destructive) {
            workspace.closeTabsRight(of: tab.id)
        }
        .disabled(!hasTabsOnRight)
    }

    @ViewBuilder
    func sessionContent(for tab: TerminalTabModel) -> some View {
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

    var fileManagerDisclosure: some View {
        VStack(spacing: 0) {
            fileManagerHeader(
                showsDisclosure: true,
                isExpanded: isFileManagerPanelVisible,
                isFocusActive: isFileManagerFocusMode,
                onToggleDisclosure: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        bottomPanelVisibility.toggleFileManager(fileManagerAvailable: shouldShowFileManager)
                    }
                },
                onToggleFocus: {
                    toggleWorkspaceFocusMode(.fileManager)
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 5)

            if isFileManagerPanelVisible {
                Divider()
                    .overlay(VisualStyle.borderSoft)
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
                    onRefreshRemote: {
                        refreshOrReconnectFileManagerForActivePane()
                    },
                    onEditDownloadPath: {
                        openSettingsAndFocusDownloadPath()
                    }
                )
                    .frame(minHeight: 280, maxHeight: fileManagerShouldFillRemainingHeight ? .infinity : 420, alignment: .top)
                    .layoutPriority(fileManagerShouldFillRemainingHeight ? 1 : 0)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        }
        .glassCard(fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft, showsShadow: false)
        .frame(maxWidth: .infinity, maxHeight: fileManagerShouldFillRemainingHeight ? .infinity : nil, alignment: .top)
        .layoutPriority(fileManagerShouldFillRemainingHeight ? 1 : 0)
    }

    var focusedTerminalWorkspace: some View {
        sessionContainer
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var focusedFileManagerWorkspace: some View {
        VStack(spacing: 0) {
            fileManagerHeader(
                showsDisclosure: false,
                isExpanded: true,
                isFocusActive: true,
                onToggleDisclosure: nil,
                onToggleFocus: {
                    toggleWorkspaceFocusMode(.fileManager)
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 5)

            Divider()
                .overlay(VisualStyle.borderSoft)

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
                onRefreshRemote: {
                    refreshOrReconnectFileManagerForActivePane()
                },
                onEditDownloadPath: {
                    openSettingsAndFocusDownloadPath()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .glassCard(fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft, showsShadow: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    func fileManagerHeader(
        showsDisclosure: Bool,
        isExpanded: Bool,
        isFocusActive: Bool,
        onToggleDisclosure: (() -> Void)?,
        onToggleFocus: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            if let onToggleDisclosure, showsDisclosure {
                Button(action: onToggleDisclosure) {
                    fileManagerHeaderTitle(disclosureState: isExpanded)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("file-manager-disclosure-toggle")
            } else {
                fileManagerHeaderTitle(disclosureState: nil)
            }

            panelFocusButton(
                isActive: isFocusActive,
                enterLabel: tr("Focus File Manager"),
                exitLabel: tr("Exit File Manager Focus")
            ) {
                onToggleFocus()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .center)
    }

    func fileManagerHeaderTitle(disclosureState: Bool?) -> some View {
        HStack(spacing: 8) {
            if let disclosureState {
                Image(systemName: disclosureState ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .frame(width: 14, height: 14, alignment: .center)
            }

            Label(tr("File Manager"), systemImage: "folder")
                .panelTitleStyle()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .contentShape(Rectangle())
    }

    func panelFocusButton(
        isActive: Bool,
        enterLabel: String,
        exitLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isActive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(VisualStyle.textSecondary)
        .accessibilityLabel(isActive ? exitLabel : enterLabel)
    }

    var sidebarEmptyState: some View {
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

    func paneView(_ pane: TerminalPaneModel, tabID: UUID) -> some View {
        let hostID = pane.runtime.reconnectableSSHHost?.id
        return TerminalPaneView(
            pane: pane,
            quickCommands: hostCatalog.quickCommands(for: hostID),
            isContentVisible: isTerminalFocusMode ? true : isTerminalPanelVisible,
            isFocused: workspace.activePaneByTab[tabID] == pane.id,
            isInFocusMode: isTerminalFocusMode,
            canClose: (workspace.tab(id: tabID)?.panes.count ?? 0) > 1,
            onSelect: {
                workspace.selectPane(pane.id, in: tabID)
            },
            onToggleCollapse: {
                withAnimation(.easeInOut(duration: 0.22)) {
                    bottomPanelVisibility.toggleTerminal(fileManagerAvailable: shouldShowFileManager)
                }
            },
            onToggleFocusMode: {
                toggleWorkspaceFocusMode(.terminal)
            },
            onReconnect: {
                reconnectSession(tabID)
            },
            onClose: {
                workspace.closePane(pane.id, in: tabID)
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
    var quickCommandManagerSheet: some View {
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
    var quickPathManagerSheet: some View {
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

    var importSourceSheet: some View {
        HostImportSourceSheet(
            onCancel: {
                isImportSourceSheetPresented = false
            },
            onSelect: { source in
                selectImportSource(source)
            }
        )
    }

    var importProgressSheet: some View {
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
