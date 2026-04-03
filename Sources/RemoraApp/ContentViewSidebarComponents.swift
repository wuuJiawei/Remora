import AppKit
import SwiftUI
import RemoraCore

struct SidebarIconButton: View {
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

struct SidebarMenuIconButton<MenuContent: View>: View {
    let systemImage: String
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var isHovering = false

    private let buttonWidth: CGFloat = 26
    private let buttonHeight: CGFloat = 24

    var body: some View {
        Menu {
            menuContent()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: buttonWidth, height: buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? VisualStyle.leftHoverBackground : Color.clear)
                )
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: buttonWidth, height: buttonHeight)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

struct SidebarActionRowButton: View {
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

struct SidebarPrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(VisualStyle.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 10)
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

enum SidebarThreadsHeaderButtonKind: CaseIterable {
    case createConnection
    case createGroup

    var systemImage: String {
        switch self {
        case .createConnection:
            return "plus.circle"
        case .createGroup:
            return "folder.badge.plus"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .createConnection:
            return "sidebar-header-create-connection"
        case .createGroup:
            return "sidebar-header-create-group"
        }
    }
}

struct SidebarThreadsHeaderActions {
    let onCreateConnection: () -> Void
    let onCreateGroup: () -> Void

    func perform(_ kind: SidebarThreadsHeaderButtonKind) {
        switch kind {
        case .createConnection:
            onCreateConnection()
        case .createGroup:
            onCreateGroup()
        }
    }
}

struct SidebarThreadsHeaderView: View {
    let actions: SidebarThreadsHeaderActions

    var body: some View {
        HStack(spacing: 8) {
            Text(tr("SSH Threads"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
            Spacer()
            SidebarIconButton(systemImage: SidebarThreadsHeaderButtonKind.createConnection.systemImage) {
                actions.perform(.createConnection)
            }
            .accessibilityIdentifier(SidebarThreadsHeaderButtonKind.createConnection.accessibilityIdentifier)

            SidebarIconButton(systemImage: SidebarThreadsHeaderButtonKind.createGroup.systemImage) {
                actions.perform(.createGroup)
            }
            .accessibilityIdentifier(SidebarThreadsHeaderButtonKind.createGroup.accessibilityIdentifier)
        }
    }
}

struct SidebarGroupSectionView: View {
    let section: HostGroupSection
    let displayName: String
    let selectedHostID: UUID?
    let dragPayload: String
    let onDropPayloads: ([String]) -> Bool
    let onDropBeforeHost: ([String], RemoraCore.Host) -> Bool
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

    private var canManageGroup: Bool {
        !section.isSystemSection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: onToggleCollapsed) {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VisualStyle.textSecondary)
                        Text(displayName)
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

                if canManageGroup {
                    SidebarIconButton(systemImage: "plus") {
                        onAddThread()
                    }
                    SidebarIconButton(systemImage: "trash") {
                        onDeleteGroup()
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 22)
            .draggable(dragPayload)
            .contextMenu {
                if canManageGroup {
                    contextMenuButton(tr("Create connection"), systemImage: ContextMenuIconCatalog.addConnection) {
                        onAddThread()
                    }
                }
                contextMenuButton(
                    isCollapsed ? tr("Expand group") : tr("Collapse group"),
                    systemImage: isCollapsed ? ContextMenuIconCatalog.expand : ContextMenuIconCatalog.collapse
                ) {
                    onToggleCollapsed()
                }
                if canManageGroup {
                    contextMenuButton(tr("Edit group"), systemImage: ContextMenuIconCatalog.editGroup) {
                        onEditGroup()
                    }
                    contextMenuButton(tr("Export group"), systemImage: ContextMenuIconCatalog.export) {
                        onExportGroup()
                    }
                    Divider()
                    contextMenuButton(tr("Delete group"), systemImage: ContextMenuIconCatalog.delete, role: .destructive) {
                        onDeleteGroup()
                    }
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
                            dragPayload: SidebarDragPayload.host(host.id).rawValue,
                            onDropPayloads: { items in
                                onDropBeforeHost(items, host)
                            },
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
        .dropDestination(for: String.self) { items, _ in
            onDropPayloads(items)
        }
    }
}

struct SidebarHostRow: View {
    let host: RemoraCore.Host
    let isSelected: Bool
    let dragPayload: String
    let onDropPayloads: ([String]) -> Bool
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
        .draggable(dragPayload)
        .dropDestination(for: String.self) { items, _ in
            onDropPayloads(items)
        }
        .accessibilityIdentifier("sidebar-host-row-\(host.name)")
        .animation(nil, value: isSelected)
        .contextMenu {
            contextMenuButton(tr("Edit connection"), systemImage: ContextMenuIconCatalog.editConnection) {
                onEdit()
            }
            Divider()
            Menu {
                contextMenuButton(tr("Copy connection info"), systemImage: ContextMenuIconCatalog.copy) {
                    onCopyConnectionInfo()
                }
                contextMenuButton(tr("Copy address"), systemImage: ContextMenuIconCatalog.copyPath) {
                    onCopyAddress()
                }
                contextMenuButton(tr("Copy SSH command"), systemImage: ContextMenuIconCatalog.copy) {
                    onCopySSHCommand()
                }
            } label: {
                Label(tr("Copy"), systemImage: ContextMenuIconCatalog.copy)
            }
            contextMenuButton(tr("Manage quick commands"), systemImage: ContextMenuIconCatalog.manageQuickCommands) {
                onManageQuickCommands()
            }
            Divider()
            contextMenuButton(tr("Delete connection"), systemImage: ContextMenuIconCatalog.delete, role: .destructive) {
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
                    .accessibilityIdentifier("sidebar-host-edit-\(host.name)")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(VisualStyle.textSecondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-host-delete-\(host.name)")
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
