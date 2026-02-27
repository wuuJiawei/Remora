import AppKit
import SwiftUI
import RemoraCore

struct ContentView: View {
    @StateObject private var workspace = WorkspaceViewModel()
    @StateObject private var hostCatalog = HostCatalogStore()
    @StateObject private var fileTransfer = FileTransferViewModel()

    @State private var hostSearchQuery = ""
    @State private var quickConnectQuery = ""
    @State private var selectedHostID: UUID?
    @State private var selectedTemplateID: UUID?
    @State private var pendingSplitOrientation: PaneSplitOrientation = .horizontal
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var isFilePanelVisible = true
    @State private var isSettingsAlertPresented = false
    @State private var collapsedGroupNames: Set<String> = []
    @State private var isRenameGroupSheetPresented = false
    @State private var renameGroupSourceName = ""
    @State private var renameGroupDraft = ""
    @State private var isRenameHostSheetPresented = false
    @State private var renameHostID: UUID?
    @State private var renameHostDraft = ""

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
    }

    private var detailWorkspace: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1260

            VStack(spacing: VisualStyle.panelSpacing) {
                controlCard(isCompact: isCompact)
                tabStripCard

                if isCompact {
                    VStack(spacing: VisualStyle.panelSpacing) {
                        terminalWorkspaceCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if isFilePanelVisible {
                            FileManagerPanelView(viewModel: fileTransfer)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .frame(minHeight: 260, maxHeight: 340)
                        }
                    }
                } else {
                    HSplitView {
                        terminalWorkspaceCard

                        if isFilePanelVisible {
                            FileManagerPanelView(viewModel: fileTransfer)
                                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
                        }
                    }
                }
            }
            .padding(VisualStyle.pagePadding)
        }
    }

    private func controlCard(isCompact: Bool) -> some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Quick Connect (alias / host)", text: $quickConnectQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            connectFromQuickQuery()
                        }

                    Button("Quick Connect") {
                        connectFromQuickQuery()
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 10)

                    Picker("Split", selection: $pendingSplitOrientation) {
                        ForEach(PaneSplitOrientation.allCases) { orientation in
                            Text(orientation.rawValue).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: isCompact ? 180 : 220)

                    Button("Split") {
                        workspace.splitActiveTab(orientation: pendingSplitOrientation)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        workspace.createTab()
                    } label: {
                        Label("Tab", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        withAnimation {
                            isFilePanelVisible.toggle()
                        }
                    } label: {
                        Label(
                            isFilePanelVisible ? "Hide Files" : "Show Files",
                            systemImage: isFilePanelVisible ? "sidebar.right" : "sidebar.left"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    HostSummaryChip(host: selectedHost)

                    if !availableTemplates.isEmpty {
                        Picker("Template", selection: $selectedTemplateID) {
                            ForEach(availableTemplates) { template in
                                Text(template.name).tag(Optional(template.id))
                            }
                        }
                        .frame(width: 230)
                    }

                    Button("Connect Active Pane") {
                        connectSelectedHostToActivePane()
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedHost == nil)

                    Button("Disconnect") {
                        workspace.disconnectActivePane()
                    }
                    .buttonStyle(.bordered)

                    if let activePane = workspace.activePane {
                        PaneStatusChip(status: activePane.runtime.connectionState)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 2)
        } label: {
            Label("Command Center", systemImage: "slider.horizontal.3")
                .panelTitleStyle()
        }
        .groupBoxStyle(.automatic)
        .glassCard()
    }

    private var tabStripCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(workspace.tabs) { tab in
                    TabPill(
                        title: tab.title,
                        isActive: workspace.activeTabID == tab.id,
                        canClose: workspace.tabs.count > 1,
                        onTap: { workspace.selectTab(tab.id) },
                        onClose: { workspace.closeTab(tab.id) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .glassCard(radius: 12, fill: VisualStyle.rightPanelBackground, border: VisualStyle.borderSoft)
    }

    private var terminalWorkspaceCard: some View {
        GroupBox {
            tabWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } label: {
            Label("Terminal Workspace", systemImage: "rectangle.split.2x1")
                .panelTitleStyle()
        }
        .glassCard()
    }

    @ViewBuilder
    private var tabWorkspace: some View {
        if let activeTab = workspace.activeTab {
            if activeTab.panes.count == 1, let pane = activeTab.panes.first {
                TerminalPaneView(
                    pane: pane,
                    isFocused: workspace.activePane?.id == pane.id,
                    onSelect: {
                        workspace.selectPane(pane.id, in: activeTab.id)
                    }
                )
            } else if activeTab.panes.count == 2 {
                if activeTab.splitOrientation == .horizontal {
                    HSplitView {
                        paneView(activeTab.panes[0], tabID: activeTab.id)
                        paneView(activeTab.panes[1], tabID: activeTab.id)
                    }
                } else {
                    VSplitView {
                        paneView(activeTab.panes[0], tabID: activeTab.id)
                        paneView(activeTab.panes[1], tabID: activeTab.id)
                    }
                }
            }
        } else {
            ContentUnavailableView("No Active Tab", systemImage: "rectangle.slash", description: Text("Create a new tab to start a session."))
        }
    }

    private func paneView(_ pane: TerminalPaneModel, tabID: UUID) -> some View {
        TerminalPaneView(
            pane: pane,
            isFocused: workspace.activePane?.id == pane.id,
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

    private func connectSelectedHostToActivePane() {
        guard let host = selectedHost else { return }
        workspace.connectActivePane(host: host, template: selectedTemplate)
        hostCatalog.markConnected(hostID: host.id)
    }

    private func connectFromQuickQuery() {
        guard let host = hostCatalog.quickConnectMatch(input: quickConnectQuery) else {
            if let pane = workspace.activePane {
                pane.runtime.connectionState = "Quick connect: host not found"
            }
            return
        }

        selectedHostID = host.id
        let template = hostCatalog.templates(for: host.id).first
        selectedTemplateID = template?.id
        workspace.connectActivePane(host: host, template: template)
        hostCatalog.markConnected(hostID: host.id)
        quickConnectQuery = ""
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

private struct HostSummaryChip: View {
    let host: RemoraCore.Host?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
            Text(host.map { "\($0.name) (\($0.address))" } ?? "No host selected")
                .lineLimit(1)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VisualStyle.leftInteractiveBackground, in: Capsule())
        .overlay(Capsule().stroke(VisualStyle.borderNormal, lineWidth: 1))
    }
}

private struct PaneStatusChip: View {
    let status: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(status)
                .lineLimit(1)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VisualStyle.leftInteractiveBackground, in: Capsule())
        .overlay(Capsule().stroke(VisualStyle.borderNormal, lineWidth: 1))
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var statusColor: Color {
        if status.hasPrefix("Connected") {
            return .green
        }
        if status.hasPrefix("Failed") {
            return .red
        }
        if status.hasPrefix("Connecting") {
            return .orange
        }
        return .secondary
    }
}

private struct TabPill: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(VisualStyle.textPrimary)
            }
            .buttonStyle(.plain)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(VisualStyle.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive || isHovering ? VisualStyle.leftInteractiveBackground : VisualStyle.rightPanelBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(isActive ? VisualStyle.borderStrong : VisualStyle.borderSoft, lineWidth: 1)
        )
        .scaleEffect(isHovering && !isActive ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: isActive)
    }
}
