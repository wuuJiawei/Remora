import AppKit
import Combine
import Foundation
import SwiftUI
import RemoraCore

private struct ActiveRuntimeSFTPState: Equatable {
    var runtimeID: ObjectIdentifier?
    var connectionMode: ConnectionMode?
    var connectionState: String
    var hostSignature: String?
}

struct ContentView: View {
    @StateObject private var workspace = WorkspaceViewModel()
    @StateObject private var hostCatalog = HostCatalogStore()
    @StateObject private var fileTransfer = FileTransferViewModel()
    @StateObject private var directorySyncBridge = TerminalDirectorySyncBridge()

    @State private var hostSearchQuery = ""
    @State private var selectedHostID: UUID?
    @State private var selectedTemplateID: UUID?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var isFilePanelVisible = false
    @State private var isSettingsAlertPresented = false
    @State private var collapsedGroupNames: Set<String> = []
    @State private var isGroupEditorSheetPresented = false
    @State private var groupEditorMode: SidebarGroupEditorMode = .create
    @State private var groupEditorSourceName = ""
    @State private var groupEditorDraft = ""
    @State private var isHostEditorSheetPresented = false
    @State private var hostEditorMode: SidebarHostEditorMode = .create
    @State private var hostEditorDraft = SidebarHostEditorDraft()
    @State private var hostEditorTestState: HostConnectionTestState = .idle
    @State private var pendingExportScope: HostExportScope?
    @State private var isExportFormatDialogPresented = false
    @State private var isExportingHosts = false
    @State private var isImportingHosts = false
    @State private var isExportResultAlertPresented = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage = ""
    @State private var isImportProgressSheetPresented = false
    @State private var importSourceFilename = ""
    @State private var importProgress = HostConnectionImportProgress(phase: "Preparing", completed: 0, total: 1)
    @State private var importResultMessage: String?
    @State private var importErrorMessage: String?
    @State private var isRenameSessionSheetPresented = false
    @State private var renameSessionID: UUID?
    @State private var renameSessionDraft = ""
    @State private var fileManagerSFTPBindingKey = "disconnected"

    private var selectedHost: RemoraCore.Host? {
        hostCatalog.host(id: selectedHostID)
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
        ZStack {
            backgroundGradient

            NavigationSplitView(columnVisibility: $splitVisibility) {
                sidebar
            } detail: {
                detailWorkspace
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 1200, minHeight: 760)
        .onAppear {
            if selectedHostID == nil {
                selectedHostID = hostCatalog.hosts.first?.id
            }
            if let firstPane = workspace.activePane {
                firstPane.runtime.connectLocalShell()
            }
            directorySyncBridge.bind(fileTransfer: fileTransfer, runtime: workspace.activePane?.runtime)
            syncFileManagerSFTPBinding()
        }
        .onChange(of: selectedHostID) {
            selectedTemplateID = availableTemplates.first?.id
        }
        .onChange(of: workspace.activeTabID) {
            directorySyncBridge.attachRuntime(workspace.activePane?.runtime)
            syncFileManagerSFTPBinding()
        }
        .onChange(of: workspace.activePaneByTab) {
            directorySyncBridge.attachRuntime(workspace.activePane?.runtime)
            syncFileManagerSFTPBinding()
        }
        .onReceive(activeRuntimeSFTPStatePublisher) { _ in
            syncFileManagerSFTPBinding()
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
                title: "New SSH Connection",
                systemImage: "plus"
            ) {
                beginCreateHostInPreferredGroup()
            }
            .accessibilityIdentifier("sidebar-new-ssh-connection")
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)

            SidebarActionRowButton(
                title: isExportingHosts ? "Exporting..." : "Export Connections",
                systemImage: "square.and.arrow.up"
            ) {
                beginExportAllHosts()
            }
            .disabled(isExportingHosts || isImportingHosts || hostCatalog.isLoading)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            SidebarActionRowButton(
                title: isImportingHosts ? "Importing..." : "Import Connections",
                systemImage: "square.and.arrow.down"
            ) {
                beginImportHosts()
            }
            .accessibilityIdentifier("sidebar-import-connections")
            .disabled(isExportingHosts || isImportingHosts || hostCatalog.isLoading)
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            TextField("Search SSH host", text: $hostSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(VisualStyle.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(VisualStyle.borderSoft, lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Text("SSH Threads")
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
                        Text("Loading SSH connections...")
                            .font(.system(size: 12))
                            .foregroundStyle(VisualStyle.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .accessibilityIdentifier("sidebar-hosts-loading")
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
                                onPinThread: { hostID in
                                    togglePinHost(hostID)
                                },
                                onEditThread: { hostID in
                                    beginEditHost(hostID)
                                },
                                onArchiveThread: { hostID in
                                    archiveHost(hostID)
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

            SidebarActionRowButton(
                title: "Settings",
                systemImage: "gearshape"
            ) {
                isSettingsAlertPresented = true
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
        .alert("Settings", isPresented: $isSettingsAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Settings page will be added in the next milestone.")
        }
        .confirmationDialog(
            "Export SSH Connections",
            isPresented: $isExportFormatDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Export as JSON") {
                startExport(format: .json)
            }
            Button("Export as CSV") {
                startExport(format: .csv)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingExportScope?.label ?? "Choose format")
        }
        .alert(exportAlertTitle, isPresented: $isExportResultAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
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
                title: "Rename Session",
                fieldTitle: "Session title",
                value: $renameSessionDraft,
                onCancel: {
                    isRenameSessionSheetPresented = false
                },
                onConfirm: {
                    commitRenameSession()
                }
            )
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
            fileManagerDisclosure
        }
        .padding(VisualStyle.pagePadding)
    }

    private var sessionContainer: some View {
        VStack(spacing: 0) {
            sessionTabBar
            Divider()
                .overlay(VisualStyle.borderSoft)
            Group {
                if workspace.tabs.isEmpty {
                    ContentUnavailableView(
                        "No Session",
                        systemImage: "rectangle.slash",
                        description: Text("Create a new session from tab bar.")
                    )
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
        .glassCard(fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft)
    }

    private var sessionTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs) { tab in
                    SessionTabBarItem(
                        title: tab.title,
                        isActive: workspace.activeTabID == tab.id,
                        canClose: workspace.tabs.count > 1,
                        onSelect: {
                            workspace.selectTab(tab.id)
                        },
                        onClose: {
                            workspace.closeTab(tab.id)
                        }
                    )
                    .contextMenu {
                        sessionContextMenu(for: tab)
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
        Button("New Session") {
            workspace.createTab()
        }

        Button("Rename Session") {
            beginRenameSession(tab.id)
        }

        if workspace.tabs.count > 1 {
            Button("Close Session", role: .destructive) {
                workspace.closeTab(tab.id)
            }
        }

        Divider()

        Button("Split Horizontal") {
            workspace.selectTab(tab.id)
            workspace.splitActiveTab(orientation: .horizontal)
        }
        .disabled(tab.panes.count > 1)

        Button("Split Vertical") {
            workspace.selectTab(tab.id)
            workspace.splitActiveTab(orientation: .vertical)
        }
        .disabled(tab.panes.count > 1)

        if selectedHost != nil {
            Divider()
            Button("Connect Selected SSH Host") {
                connectSelectedHost(to: tab.id)
            }
            Button("Disconnect Session") {
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
                "Invalid Session State",
                systemImage: "exclamationmark.triangle",
                description: Text("Session pane count is not supported.")
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
                    Label("File Manager", systemImage: "folder")
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
                FileManagerPanelView(viewModel: fileTransfer)
                    .frame(minHeight: 280, maxHeight: 420, alignment: .top)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft)
    }

    private func paneView(_ pane: TerminalPaneModel, tabID: UUID) -> some View {
        TerminalPaneView(
            pane: pane,
            isFocused: workspace.activePaneByTab[tabID] == pane.id,
            onSelect: {
                workspace.selectPane(pane.id, in: tabID)
            }
        )
        .id(pane.id)
    }

    private func toggleGroupCollapse(_ groupName: String) {
        if collapsedGroupNames.contains(groupName) {
            collapsedGroupNames.remove(groupName)
        } else {
            collapsedGroupNames.insert(groupName)
        }
    }

    private func beginCreateHostInPreferredGroup() {
        let preferredGroup = selectedHost?.group ?? hostCatalog.groups.first ?? "Default"
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
            hostEditorTestState = .failure("Port must be between 1 and 65535.")
            return
        }

        let address = hostEditorDraft.address
        guard !address.isEmpty else {
            hostEditorTestState = .failure("Host cannot be empty.")
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
        pendingExportScope = .all
        isExportFormatDialogPresented = true
    }

    private func beginExportGroup(_ groupName: String) {
        guard !isExportingHosts else { return }
        pendingExportScope = .group(groupName)
        isExportFormatDialogPresented = true
    }

    private func startExport(format: HostExportFormat) {
        guard let scope = pendingExportScope else { return }
        let hosts = hostCatalog.hosts
        pendingExportScope = nil
        isExportingHosts = true

        Task {
            do {
                let outputURL = try await HostConnectionExporter.export(
                    hosts: hosts,
                    scope: scope,
                    format: format
                )
                await MainActor.run {
                    exportAlertTitle = "Export Complete"
                    exportAlertMessage = "Saved to \(outputURL.path)"
                    isExportResultAlertPresented = true
                    isExportingHosts = false
                }
            } catch {
                await MainActor.run {
                    exportAlertTitle = "Export Failed"
                    exportAlertMessage = error.localizedDescription
                    isExportResultAlertPresented = true
                    isExportingHosts = false
                }
            }
        }
    }

    private func beginImportHosts() {
        guard !isImportingHosts else { return }

        let panel = NSOpenPanel()
        panel.title = "Import SSH Connections"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.urls.first {
            startImport(from: url)
        }
    }

    private func startImport(from fileURL: URL) {
        guard !isImportingHosts else { return }
        isImportingHosts = true
        importSourceFilename = fileURL.lastPathComponent
        importProgress = HostConnectionImportProgress(phase: "Preparing", completed: 0, total: 1)
        importResultMessage = nil
        importErrorMessage = nil
        isImportProgressSheetPresented = true

        Task {
            do {
                let importedHosts = try await HostConnectionImporter.importConnections(
                    from: fileURL,
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
                        phase: "Completed",
                        completed: max(summary.total, 1),
                        total: max(summary.total, 1)
                    )
                    importResultMessage = "Imported \(summary.created) new, updated \(summary.updated), total \(summary.total)."
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

    private func togglePinHost(_ hostID: UUID) {
        hostCatalog.toggleFavorite(hostID: hostID)
    }

    private func archiveHost(_ hostID: UUID) {
        hostCatalog.archiveHost(id: hostID)
        collapsedGroupNames.remove("Archived")
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyConnectionInfo(_ host: RemoraCore.Host) {
        Task {
            let text = await HostConnectionClipboardBuilder.connectionInfoText(for: host)
            await MainActor.run {
                copyToPasteboard(text)
            }
        }
    }

    private func connectSelectedHost(to tabID: UUID) {
        guard let host = selectedHost else { return }
        workspace.selectTab(tabID)
        workspace.connectActivePane(host: host, template: selectedTemplate)
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
        hostCatalog.markConnected(hostID: host.id)
    }

    private func disconnectSession(_ tabID: UUID) {
        workspace.selectTab(tabID)
        workspace.disconnectActivePane()
    }

    private func syncFileManagerSFTPBinding() {
        guard let runtime = workspace.activePane?.runtime else {
            bindDisconnectedSFTPIfNeeded()
            return
        }

        let isConnectedSSH = runtime.connectionMode == .ssh
            && runtime.connectionState.hasPrefix("Connected")
        if isConnectedSSH, let host = runtime.connectedSSHHost {
            let signature = "ssh:\(Self.sftpHostSignature(for: host))"
            guard fileManagerSFTPBindingKey != signature else { return }
            fileManagerSFTPBindingKey = signature
            fileTransfer.bindSFTPClient(
                SystemSFTPClient(host: host),
                initialRemoteDirectory: runtime.workingDirectory ?? "/"
            )
            return
        }

        bindDisconnectedSFTPIfNeeded()
    }

    private func bindDisconnectedSFTPIfNeeded() {
        guard fileManagerSFTPBindingKey != "disconnected" else { return }
        fileManagerSFTPBindingKey = "disconnected"
        fileTransfer.bindSFTPClient(DisconnectedSFTPClient(), initialRemoteDirectory: "/")
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

    private var importProgressSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import SSH Connections")
                .font(.headline)

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
                Button("Close") {
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
    let onPinThread: (UUID) -> Void
    let onEditThread: (UUID) -> Void
    let onArchiveThread: (UUID) -> Void
    let onCopyConnectionInfo: (RemoraCore.Host) -> Void
    let onCopyAddress: (RemoraCore.Host) -> Void
    let onCopySSHCommand: (RemoraCore.Host) -> Void
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
                Button("Create connection") {
                    onAddThread()
                }
                Button(isCollapsed ? "Expand group" : "Collapse group") {
                    onToggleCollapsed()
                }
                Button("Edit group") {
                    onEditGroup()
                }
                Button("Export group") {
                    onExportGroup()
                }
                Divider()
                Button("Delete group", role: .destructive) {
                    onDeleteGroup()
                }
            }

            if !isCollapsed {
                if section.hosts.isEmpty {
                    Text("No SSH threads")
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
                            onPin: {
                                onPinThread(host.id)
                            },
                            onEdit: {
                                onEditThread(host.id)
                            },
                            onArchive: {
                                onArchiveThread(host.id)
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

private struct SidebarHostRow: View {
    let host: RemoraCore.Host
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onPin: () -> Void
    let onEdit: () -> Void
    let onArchive: () -> Void
    let onCopyConnectionInfo: () -> Void
    let onCopyAddress: () -> Void
    let onCopySSHCommand: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: host.favorite ? "star.fill" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VisualStyle.textPrimary)
                    .lineLimit(1)
                Text(host.group)
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
                    .background(Capsule().fill(Color.white.opacity(0.45)))
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
        .onTapGesture(count: 2) {
            onOpen()
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button(host.favorite ? "Unpin connection" : "Pin connection") {
                onPin()
            }
            Button("Edit connection") {
                onEdit()
            }
            Button("Archive connection") {
                onArchive()
            }
            Divider()
            Menu("Copy") {
                Button("Copy connection info") {
                    onCopyConnectionInfo()
                }
                Button("Copy address") {
                    onCopyAddress()
                }
                Button("Copy SSH command") {
                    onCopySSHCommand()
                }
            }
            Divider()
            Button("Delete connection", role: .destructive) {
                onDelete()
            }
        }
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
            return "New Thread Group"
        case .edit:
            return "Edit Thread Group"
        }
    }

    var confirmTitle: String {
        switch self {
        case .create:
            return "Create"
        case .edit:
            return "Save"
        }
    }
}

private enum SidebarHostEditorMode {
    case create
    case edit(UUID)

    var title: String {
        switch self {
        case .create:
            return "New SSH Connection"
        case .edit:
            return "Edit SSH Connection"
        }
    }

    var confirmTitle: String {
        switch self {
        case .create:
            return "Create"
        case .edit:
            return "Save"
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

    init(preferredGroup: String = "Default") {
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
        return trimmed.isEmpty ? "Default" : trimmed
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
                        continuation.resume(returning: .success("Connection test passed (\(host):\(port))."))
                    } else if !errorText.isEmpty {
                        continuation.resume(returning: .failure(errorText))
                    } else {
                        continuation.resume(returning: .failure("Cannot reach \(host):\(port)."))
                    }
                } catch {
                    continuation.resume(returning: .failure("Connection test failed: \(error.localizedDescription)"))
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

            TextField("Group name", text: $value)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
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
                TextField("Connection name", text: $draft.connectionName)
                TextField("Host", text: $draft.hostAddress)

                HStack(spacing: 10) {
                    TextField("Port", text: $draft.portText)
                        .frame(width: 90)
                    TextField("Username", text: $draft.usernameText)
                }

                TextField("Group", text: $draft.groupText)

                Picker("Auth", selection: $draft.authMethod) {
                    ForEach(SidebarHostAuthMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.menu)

                if draft.authMethod == .privateKey {
                    TextField("Private key path", text: $draft.privateKeyPath)
                }

                if draft.authMethod == .password {
                    HStack(spacing: 8) {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $draft.password)
                            } else {
                                SecureField("Password", text: $draft.password)
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
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                        .help(isPasswordVisible ? "Hide password" : "Show password")
                    }
                    Toggle("Save password", isOn: $draft.savePassword)
                        .toggleStyle(.checkbox)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Test Connection", action: onTestConnection)
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
                Button("Cancel", action: onCancel)
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
                Button("Cancel") {
                    onCancel()
                }
                Button("Save") {
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

private struct SessionTabBarItem: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Text(title)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VisualStyle.textPrimary)
            }
            .buttonStyle(.plain)

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
    }
}
