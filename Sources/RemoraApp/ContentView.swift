import AppKit
import SwiftUI
import RemoraCore

struct ContentView: View {
    @StateObject private var workspace = WorkspaceViewModel()
    @StateObject private var hostCatalog = HostCatalogStore()
    @StateObject private var fileTransfer = FileTransferViewModel()

    @State private var hostSearchQuery = ""
    @State private var selectedHostID: UUID?
    @State private var selectedTemplateID: UUID?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var isFilePanelVisible = false
    @State private var isSettingsAlertPresented = false
    @State private var collapsedGroupNames: Set<String> = []
    @State private var isRenameGroupSheetPresented = false
    @State private var renameGroupSourceName = ""
    @State private var renameGroupDraft = ""
    @State private var isRenameHostSheetPresented = false
    @State private var renameHostID: UUID?
    @State private var renameHostDraft = ""
    @State private var isRenameSessionSheetPresented = false
    @State private var renameSessionID: UUID?
    @State private var renameSessionDraft = ""

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
                firstPane.runtime.connectMock()
            }
        }
        .onChange(of: selectedHostID) {
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
                createHostInPreferredGroup()
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
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
                    let groupName = hostCatalog.addGroup()
                    collapsedGroupNames.remove(groupName)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            ScrollView {
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
                                createHost(in: section.name)
                            },
                            onRenameGroup: {
                                beginRenameGroup(section.name)
                            },
                            onDeleteGroup: {
                                deleteGroup(section.name)
                            },
                            onSelectThread: { hostID in
                                selectedHostID = hostID
                            },
                            onPinThread: { hostID in
                                togglePinHost(hostID)
                            },
                            onRenameThread: { hostID in
                                beginRenameHost(hostID)
                            },
                            onArchiveThread: { hostID in
                                archiveHost(hostID)
                            },
                            onCopyAddress: { host in
                                copyToPasteboard(host.address)
                            },
                            onCopySSHCommand: { host in
                                let command = "ssh \(host.username)@\(host.address) -p \(host.port)"
                                copyToPasteboard(command)
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
        .sheet(isPresented: $isRenameGroupSheetPresented) {
            SidebarRenameSheet(
                title: "Rename Thread Group",
                fieldTitle: "Group name",
                value: $renameGroupDraft,
                onCancel: {
                    isRenameGroupSheetPresented = false
                },
                onConfirm: {
                    commitRenameGroup()
                }
            )
        }
        .sheet(isPresented: $isRenameHostSheetPresented) {
            SidebarRenameSheet(
                title: "Rename Connection",
                fieldTitle: "Connection name",
                value: $renameHostDraft,
                onCancel: {
                    isRenameHostSheetPresented = false
                },
                onConfirm: {
                    commitRenameHost()
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
                if let activeTab = workspace.activeTab {
                    sessionContent(for: activeTab)
                } else {
                    ContentUnavailableView(
                        "No Session",
                        systemImage: "rectangle.slash",
                        description: Text("Create a new session from tab bar.")
                    )
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
            .zIndex(1)

            if isFilePanelVisible {
                Divider()
                    .overlay(VisualStyle.borderSoft)
                    .padding(.top, 6)
                FileManagerPanelView(viewModel: fileTransfer)
                    .frame(minHeight: 240, maxHeight: 320)
                    .padding(.top, 8)
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
    }

    private func toggleGroupCollapse(_ groupName: String) {
        if collapsedGroupNames.contains(groupName) {
            collapsedGroupNames.remove(groupName)
        } else {
            collapsedGroupNames.insert(groupName)
        }
    }

    private func createHostInPreferredGroup() {
        let preferredGroup = selectedHost?.group ?? hostCatalog.groups.first ?? hostCatalog.addGroup(named: "Default")
        createHost(in: preferredGroup)
    }

    private func createHost(in groupName: String) {
        let host = hostCatalog.addHost(in: groupName)
        collapsedGroupNames.remove(groupName)
        selectedHostID = host.id
        selectedTemplateID = nil
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

    private func beginRenameGroup(_ groupName: String) {
        renameGroupSourceName = groupName
        renameGroupDraft = groupName
        isRenameGroupSheetPresented = true
    }

    private func commitRenameGroup() {
        let oldName = renameGroupSourceName
        let newName = renameGroupDraft
        isRenameGroupSheetPresented = false
        guard !oldName.isEmpty else { return }
        if let finalName = hostCatalog.renameGroup(from: oldName, to: newName),
           collapsedGroupNames.remove(oldName) != nil
        {
            collapsedGroupNames.insert(finalName)
        }
        renameGroupSourceName = ""
    }

    private func beginRenameHost(_ hostID: UUID) {
        guard let host = hostCatalog.host(id: hostID) else { return }
        renameHostID = hostID
        renameHostDraft = host.name
        isRenameHostSheetPresented = true
    }

    private func commitRenameHost() {
        isRenameHostSheetPresented = false
        guard let renameHostID else { return }
        _ = hostCatalog.renameHost(id: renameHostID, to: renameHostDraft)
        self.renameHostID = nil
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

    private func connectSelectedHost(to tabID: UUID) {
        guard let host = selectedHost else { return }
        workspace.selectTab(tabID)
        workspace.connectActivePane(host: host, template: selectedTemplate)
        hostCatalog.markConnected(hostID: host.id)
    }

    private func disconnectSession(_ tabID: UUID) {
        workspace.selectTab(tabID)
        workspace.disconnectActivePane()
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
    let onRenameGroup: () -> Void
    let onDeleteGroup: () -> Void
    let onSelectThread: (UUID) -> Void
    let onPinThread: (UUID) -> Void
    let onRenameThread: (UUID) -> Void
    let onArchiveThread: (UUID) -> Void
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
                Button("Rename group") {
                    onRenameGroup()
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
                            onPin: {
                                onPinThread(host.id)
                            },
                            onRename: {
                                onRenameThread(host.id)
                            },
                            onArchive: {
                                onArchiveThread(host.id)
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
    let onPin: () -> Void
    let onRename: () -> Void
    let onArchive: () -> Void
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
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
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
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button(host.favorite ? "Unpin connection" : "Pin connection") {
                onPin()
            }
            Button("Rename connection") {
                onRename()
            }
            Button("Archive connection") {
                onArchive()
            }
            Divider()
            Button("Copy address") {
                onCopyAddress()
            }
            Button("Copy SSH command") {
                onCopySSHCommand()
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
