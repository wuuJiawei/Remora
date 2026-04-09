import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import RemoraCore

extension ContentView {
    func runtimeForTab(_ tab: TerminalTabModel) -> TerminalRuntime? {
        let preferredPaneID = workspace.activePaneByTab[tab.id]
        if let preferredPaneID,
           let preferredPane = tab.panes.first(where: { $0.id == preferredPaneID })
        {
            return preferredPane.runtime
        }
        return tab.panes.first?.runtime
    }

    func toggleGroupCollapse(_ groupName: String) {
        if collapsedGroupNames.contains(groupName) {
            collapsedGroupNames.remove(groupName)
        } else {
            collapsedGroupNames.insert(groupName)
        }
    }

    func toggleSSHSidebarVisibility() {
        splitVisibility = splitVisibility == .detailOnly ? .all : .detailOnly
    }

    func normalizeBottomPanelVisibility() {
        bottomPanelVisibility.normalize(fileManagerAvailable: shouldShowFileManager)
    }

    func toggleWorkspaceFocusMode(_ target: WorkspaceFocusMode) {
        if workspaceFocusMode == target {
            exitWorkspaceFocusMode()
        } else {
            enterWorkspaceFocusMode(target)
        }
    }

    func enterWorkspaceFocusMode(_ target: WorkspaceFocusMode) {
        guard target != .none else {
            exitWorkspaceFocusMode()
            return
        }
        guard canEnterWorkspaceFocusMode(target) else { return }

        if !workspaceFocusMode.isActive {
            splitVisibilityBeforeFocusMode = splitVisibility
        }

        workspaceFocusMode = target
        splitVisibility = .detailOnly
    }

    func exitWorkspaceFocusMode() {
        workspaceFocusMode = .none
        if let previousVisibility = splitVisibilityBeforeFocusMode {
            splitVisibility = previousVisibility
        }
        splitVisibilityBeforeFocusMode = nil
    }

    func normalizeWorkspaceFocusMode() {
        guard workspaceFocusMode.isActive else { return }
        guard canEnterWorkspaceFocusMode(workspaceFocusMode) else {
            exitWorkspaceFocusMode()
            return
        }

        if splitVisibility != .detailOnly {
            splitVisibility = .detailOnly
        }
    }

    func canEnterWorkspaceFocusMode(_ target: WorkspaceFocusMode) -> Bool {
        switch target {
        case .none:
            return true
        case .terminal:
            return workspace.activePane != nil
        case .fileManager:
            return shouldShowFileManager && !workspace.tabs.isEmpty
        }
    }

    func beginCreateHostInPreferredGroup() {
        let preferredGroup = selectedHost?.group == HostCatalogStore.ungroupedGroupIdentifier
            ? ""
            : (selectedHost?.group ?? "")
        beginCreateHost(in: preferredGroup)
    }

    func beginCreateHost(in groupName: String) {
        hostEditorMode = .create
        hostEditorDraft = SidebarHostEditorDraft(preferredGroup: groupName)
        hostEditorTestState = .idle
        isHostEditorSheetPresented = true
    }

    func beginEditHost(_ hostID: UUID) {
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
    func commitHostEditor() async {
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
    func buildHostFromEditorDraft() async -> RemoraCore.Host? {
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

        let oldPasswordReference = existingHost?.auth.passwordReference
        let newPasswordValue = hostEditorDraft.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordReference = await HostPasswordStorage.persist(
            authMethod: {
                switch hostEditorDraft.authMethod {
                case .agent:
                    return .agent
                case .privateKey:
                    return .privateKey
                case .password:
                    return .password
                }
            }(),
            savePassword: hostEditorDraft.savePassword,
            newPasswordValue: newPasswordValue,
            oldPasswordReference: oldPasswordReference,
            hostID: hostID,
            credentialStore: CredentialStore()
        )

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

    func testHostConnection() {
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

    func beginCreateGroup() {
        groupEditorMode = .create
        groupEditorSourceName = ""
        groupEditorDraft = ""
        isGroupEditorSheetPresented = true
    }

    func beginEditGroup(_ groupName: String) {
        groupEditorMode = .edit
        groupEditorSourceName = groupName
        groupEditorDraft = groupName
        isGroupEditorSheetPresented = true
    }

    func commitGroupEditor() {
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

    func beginExportAllHosts() {
        guard !isExportingHosts else { return }
        exportDraft = HostExportDraft(scope: .all)
        isExportSheetPresented = true
    }

    func beginExportGroup(_ groupName: String) {
        guard !isExportingHosts else { return }
        exportDraft = HostExportDraft(scope: .group(groupName))
        isExportSheetPresented = true
    }

    func displayGroupName(_ groupName: String) -> String {
        if groupName == HostCatalogStore.ungroupedGroupIdentifier {
            return tr("Ungrouped")
        }
        return groupName
    }

    func startExport(with draft: HostExportDraft) {
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

    func beginImportHosts() {
        guard !isImportingHosts else { return }
        isImportSourceSheetPresented = true
    }

    func beginImportHosts(from source: HostConnectionImportSource) {
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

    func selectImportSource(_ source: HostConnectionImportSource) {
        guard source.isSupported else { return }
        isImportSourceSheetPresented = false
        DispatchQueue.main.async {
            beginImportHosts(from: source)
        }
    }

    func startImport(from fileURL: URL, source: HostConnectionImportSource) {
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

    func deleteGroup(_ groupName: String) {
        guard groupName != HostCatalogStore.ungroupedGroupIdentifier else { return }
        let hostCount = hostCatalog.hosts.filter { $0.group == groupName }.count
        pendingGroupDeletion = PendingGroupDeletion(
            id: groupName,
            hostCount: hostCount,
            deleteHosts: false
        )
    }

    func confirmGroupDeletion(_ pending: PendingGroupDeletion) {
        hostCatalog.deleteGroup(named: pending.id, deleteHosts: pending.deleteHosts)
        pendingGroupDeletion = nil
        collapsedGroupNames.remove(pending.id)
        if let selectedHostID, hostCatalog.host(id: selectedHostID) == nil {
            self.selectedHostID = nil
            selectedTemplateID = nil
        }
    }

    func deleteHost(_ hostID: UUID) {
        hostCatalog.deleteHost(id: hostID)
        if selectedHostID == hostID {
            selectedHostID = nil
            selectedTemplateID = nil
        }
    }

    func requestHostDeletion(_ hostID: UUID) {
        guard let host = hostCatalog.host(id: hostID) else { return }
        pendingHostDeletion = PendingHostDeletion(
            id: host.id,
            name: host.name,
            address: host.address
        )
    }

    func confirmHostDeletion(_ pending: PendingHostDeletion) {
        pendingHostDeletion = nil
        deleteHost(pending.id)
    }

    func handleDropPayloads(_ items: [String], intoGroup groupName: String) -> Bool {
        guard let payload = items.compactMap(SidebarDragPayload.init).first else { return false }
        switch payload {
        case .host(let hostID):
            hostCatalog.moveHost(id: hostID, toGroup: groupName)
            collapsedGroupNames.remove(groupName)
            return true
        case .group(let draggedGroup):
            hostCatalog.moveGroup(named: draggedGroup, before: groupName)
            return true
        }
    }

    func handleDropPayloads(_ items: [String], beforeHost host: RemoraCore.Host) -> Bool {
        guard let payload = items.compactMap(SidebarDragPayload.init).first else { return false }
        guard case .host(let hostID) = payload else { return false }
        hostCatalog.moveHost(id: hostID, toGroup: host.group, before: host.id)
        if host.group != HostCatalogStore.ungroupedGroupIdentifier {
            collapsedGroupNames.remove(host.group)
        }
        return true
    }

    func handleDropPayloadsIntoUngrouped(_ items: [String]) -> Bool {
        guard let payload = items.compactMap(SidebarDragPayload.init).first else { return false }
        guard case .host(let hostID) = payload else { return false }
        hostCatalog.moveHost(id: hostID, toGroup: HostCatalogStore.ungroupedGroupIdentifier)
        return true
    }

    func beginRenameSession(_ tabID: UUID) {
        guard let tab = workspace.tab(id: tabID) else { return }
        renameSessionID = tabID
        renameSessionDraft = tab.title
        isRenameSessionSheetPresented = true
    }

    func commitRenameSession() {
        isRenameSessionSheetPresented = false
        guard let renameSessionID else { return }
        workspace.renameTab(renameSessionID, title: renameSessionDraft)
        self.renameSessionID = nil
    }

    func beginManageQuickCommands(for hostID: UUID) {
        quickCommandEditorHostID = hostID
        resetQuickCommandDraft()
    }

    func dismissQuickCommandEditor() {
        quickCommandEditorHostID = nil
        resetQuickCommandDraft()
    }

    func resetQuickCommandDraft() {
        quickCommandEditingID = nil
        quickCommandNameDraft = ""
        quickCommandBodyDraft = ""
        quickCommandValidationMessage = nil
    }

    func beginEditQuickCommand(_ quickCommand: HostQuickCommand) {
        quickCommandEditingID = quickCommand.id
        quickCommandNameDraft = quickCommand.name
        quickCommandBodyDraft = quickCommand.command
        quickCommandValidationMessage = nil
    }

    func commitQuickCommandDraft() {
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

    func deleteQuickCommand(_ quickCommandID: UUID, hostID: UUID) {
        hostCatalog.deleteQuickCommand(hostID: hostID, quickCommandID: quickCommandID)
        if quickCommandEditingID == quickCommandID {
            resetQuickCommandDraft()
        }
    }

    func runQuickCommand(_ quickCommand: HostQuickCommand, in runtime: TerminalRuntime) {
        guard let request = quickCommand.executionRequest() else { return }
        runtime.sendText(request.text, bracketedPaste: request.usesBracketedPaste)
        runtime.sendText("\n")
    }

    func beginManageQuickPaths(for hostID: UUID) {
        quickPathEditorHostID = hostID
        resetQuickPathDraft()
    }

    func dismissQuickPathEditor() {
        quickPathEditorHostID = nil
        resetQuickPathDraft()
    }

    func resetQuickPathDraft() {
        quickPathEditingID = nil
        quickPathNameDraft = ""
        quickPathValueDraft = ""
        quickPathValidationMessage = nil
    }

    func beginEditQuickPath(_ quickPath: HostQuickPath) {
        quickPathEditingID = quickPath.id
        quickPathNameDraft = quickPath.name
        quickPathValueDraft = quickPath.path
        quickPathValidationMessage = nil
    }

    func commitQuickPathDraft() {
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

    func deleteQuickPath(_ quickPathID: UUID, hostID: UUID) {
        hostCatalog.deleteQuickPath(hostID: hostID, quickPathID: quickPathID)
        if quickPathEditingID == quickPathID {
            resetQuickPathDraft()
        }
    }

    func runQuickPath(_ quickPath: HostQuickPath) {
        fileTransfer.navigateRemote(to: quickPath.path)
    }

    func addCurrentPathToQuickPaths(_ currentPath: String, hostID: UUID) {
        let normalized = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let name = defaultQuickPathName(for: normalized)
        _ = hostCatalog.addQuickPath(hostID: hostID, name: name, path: normalized)
    }

    func defaultQuickPathName(for path: String) -> String {
        if path == "/" { return tr("Root") }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return fileName.isEmpty ? path : fileName
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copyConnectionInfo(_ host: RemoraCore.Host) {
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

    func connectionInfoPasswordCopyDecision(
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

    func hasSavedPassword(for host: RemoraCore.Host) async -> Bool {
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

    func copyConnectionInfoToPasteboard(_ host: RemoraCore.Host, includePassword: Bool) {
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

    func applyConnectionInfoPasswordCopyChoice(_ choice: ConnectionInfoPasswordCopyConsentChoice) {
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

    func openHostInNewSession(_ hostID: UUID) {
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

    func disconnectSession(_ tabID: UUID) {
        workspace.selectTab(tabID)
        workspace.disconnectActivePane()
    }

    func reconnectSession(_ tabID: UUID) {
        guard let tab = workspace.tab(id: tabID),
              let runtime = runtimeForTab(tab),
              let host = runtime.reconnectableSSHHost
        else {
            return
        }

        workspace.selectTab(tabID)
        runtime.reconnectSSHSession()
        bootstrapFileManagerBindingForActiveRuntime()
        hostCatalog.markConnected(hostID: host.id)
    }

    func refreshOrReconnectFileManagerForActivePane() {
        guard let activeTabID = workspace.activeTabID,
              let runtime = workspace.activePane?.runtime
        else {
            fileTransfer.performContextAction(.refresh)
            return
        }

        let decision = SSHRefreshActionDecision.resolve(
            connectionState: runtime.connectionState,
            hasReconnectableHost: runtime.reconnectableSSHHost != nil
        )

        switch decision {
        case .refresh:
            fileTransfer.performContextAction(.refresh)
        case .reconnect:
            reconnectSession(activeTabID)
        }
    }

    func openSettingsAndFocusDownloadPath() {
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: .remoraOpenDownloadDirectorySetting, object: nil)
        }
    }

    func syncServerMetricsTracking() {
        let connectedHosts = workspace.tabs.compactMap { tab in
            runtimeForTab(tab)?.connectedSSHHost
        }
        let activeHost = workspace.activePane?.runtime.connectedSSHHost
        serverMetricsCenter.updateTrackedHosts(connectedHosts, activeHost: activeHost)
    }

    func syncServerMetricsConfiguration() {
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

    func openServerStatusWindow(for host: RemoraCore.Host, runtime: TerminalRuntime) {
        serverStatusWindowManager.present(
            host: host,
            runtime: runtime,
            metricsCenter: serverMetricsCenter
        )
    }

    func syncFileManagerSFTPBinding() {
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

    func bindDisconnectedSFTPIfNeeded(bindingKey: String) {
        guard fileManagerSFTPBindingKey != bindingKey else { return }
        fileManagerSFTPBindingKey = bindingKey
        fileTransfer.bindSFTPClient(
            DisconnectedSFTPClient(),
            bindingKey: bindingKey,
            initialRemoteDirectory: "/"
        )
    }

    func bootstrapFileManagerBindingForActiveRuntime() {
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

    static func sftpHostSignature(for host: RemoraCore.Host) -> String {
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

    static func fileManagerBindingKey(tabID: UUID, paneID: UUID, host: RemoraCore.Host) -> String {
        "tab:\(tabID.uuidString)|pane:\(paneID.uuidString)|ssh:\(sftpHostSignature(for: host))"
    }

    static func fileManagerDisconnectedBindingKey(tabID: UUID, paneID: UUID) -> String {
        "tab:\(tabID.uuidString)|pane:\(paneID.uuidString)|disconnected"
    }
}
