import AppKit
import SwiftUI
import RemoraCore

struct FileManagerOperationToast: Identifiable, Equatable {
    var id = UUID()
    var message: String
}

enum FileManagerRemoteCreateKind {
    case file
    case directory

    var title: String {
        switch self {
        case .file:
            return tr("New File")
        case .directory:
            return tr("New Folder")
        }
    }

    var defaultName: String {
        switch self {
        case .file:
            return "untitled.txt"
        case .directory:
            return tr("New Folder")
        }
    }
}

enum FileManagerRemoteSortColumn: String {
    case name
    case permission
    case date
    case size
    case kind
}

struct FileManagerRemoteListRowItem: Identifiable, Equatable {
    var path: String
    var displayName: String
    var name: String
    var parentPath: String
    var size: Int64?
    var permissions: UInt16?
    var modifiedAt: Date?
    var isDirectory: Bool
    var permissionText: String
    var modifiedAtText: String
    var sizeText: String
    var kindText: String
    var sourceEntry: RemoteFileEntry?

    var id: String { path }
}

struct FileManagerRemoteListPresentationCache {
    var items: [FileManagerRemoteListRowItem]
    var paths: [String]
    var itemsByPath: [String: FileManagerRemoteListRowItem]

    static let empty = FileManagerRemoteListPresentationCache(items: [], paths: [], itemsByPath: [:])
}

struct FileManagerRemoteTreeNode: Identifiable, Equatable {
    var path: String
    var name: String
    var depth: Int
    var isExpanded: Bool
    var isLoading: Bool
    var childrenLoaded: Bool
    var children: [FileManagerRemoteTreeNode]

    var id: String { path }
}

enum FileManagerRemoteSidebarItem: Hashable {
    case quickPath(UUID)
    case directory(String)
}

struct FileManagerRemoteSidebarRow: View {
    let title: String
    let systemImage: String
    let depth: Int
    let isSelected: Bool
    let isExpandable: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let onToggleExpansion: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if isExpandable {
                Button {
                    onToggleExpansion?()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 10, height: 10)
                        }
                    }
                    .foregroundStyle(secondaryColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 10, height: 10)
            }

            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(primaryColor)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var primaryColor: Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : VisualStyle.textPrimary
    }

    private var secondaryColor: Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.82) : VisualStyle.textSecondary
    }

    private var iconColor: Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor.opacity(0.9)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.accentColor : Color.clear)
    }
}

struct FileManagerRemoteListRowView: View {
    let item: FileManagerRemoteListRowItem
    let rowIndex: Int
    let isSelected: Bool
    let isHovered: Bool
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .foregroundStyle(secondaryTextColor)
                Text(item.displayName)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(primaryTextColor)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.permissionText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(item.modifiedAtText)
                .font(.system(size: 13))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            Text(item.sizeText)
                .font(.system(size: 13))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)

            Text(item.kindText)
                .font(.system(size: 13))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
        }
        .overlay(alignment: .trailing) {
            if isDropTarget {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.trailing, 4)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .help(tr("Drop target"))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var primaryTextColor: Color {
        (isSelected || isDropTarget)
            ? Color(nsColor: .alternateSelectedControlTextColor)
            : VisualStyle.textPrimary
    }

    private var secondaryTextColor: Color {
        (isSelected || isDropTarget)
            ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8)
            : VisualStyle.textSecondary
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor
        }
        if isDropTarget {
            return Color.accentColor.opacity(0.24)
        }
        if isHovered {
            return Color(nsColor: NSColor.alternatingContentBackgroundColors.first ?? .controlBackgroundColor)
                .opacity(0.9)
        }
        let stripe = rowIndex.isMultiple(of: 2)
            ? NSColor.controlBackgroundColor
            : NSColor.alternatingContentBackgroundColors.first ?? .controlBackgroundColor
        return Color(nsColor: stripe)
    }
}

struct FileManagerRemoteSidebarView: View {
    let remoteDirectoryPath: String
    let quickPaths: [HostQuickPath]
    let remoteTreeRoot: FileManagerRemoteTreeNode
    let visibleRemoteTreeNodes: [FileManagerRemoteTreeNode]
    let selectedItem: FileManagerRemoteSidebarItem
    let currentBreadcrumbs: [String]
    let onSelectRoot: () -> Void
    let onSelectQuickPath: (HostQuickPath) -> Void
    let onSelectDirectory: (String) -> Void
    let onToggleDirectory: (String) -> Void
    let onManageQuickPaths: () -> Void
    let onAddCurrentQuickPath: () -> Void
    let onRenameQuickPath: (HostQuickPath) -> Void
    let onDeleteQuickPath: (HostQuickPath) -> Void
    let onCopyDirectoryPath: (String) -> Void
    let onRefreshDirectory: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    quickPathsSection
                    directoryTreeSection
                }
                .padding(8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(tr("Remote"), systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(VisualStyle.textPrimary)

                Spacer(minLength: 0)

                Button(tr("Manage")) {
                    onManageQuickPaths()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .accessibilityIdentifier("file-manager-sidebar-manage-quick-paths")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(currentBreadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        Text(crumb)
                            .font(.system(size: 11, weight: index + 1 == currentBreadcrumbs.count ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(index + 1 == currentBreadcrumbs.count ? VisualStyle.textPrimary : VisualStyle.textSecondary)
                            .lineLimit(1)

                        if index + 1 < currentBreadcrumbs.count {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(VisualStyle.textTertiary)
                        }
                    }
                }
            }

            Text(remoteDirectoryPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VisualStyle.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var quickPathsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionHeader(tr("Quick Paths"))
                Spacer(minLength: 0)
                Button {
                    onAddCurrentQuickPath()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(tr("Add current path"))
                .accessibilityIdentifier("file-manager-sidebar-add-quick-path")
            }

            Button(action: onSelectRoot) {
                FileManagerRemoteSidebarRow(
                    title: tr("Root"),
                    systemImage: "house",
                    depth: 0,
                    isSelected: selectedItem == .directory("/"),
                    isExpandable: false,
                    isExpanded: false,
                    isLoading: false,
                    onToggleExpansion: nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("file-manager-sidebar-root")

            ForEach(quickPaths) { quickPath in
                Button {
                    onSelectQuickPath(quickPath)
                } label: {
                    FileManagerRemoteSidebarRow(
                        title: quickPath.name,
                        systemImage: "bookmark.fill",
                        depth: 0,
                        isSelected: selectedItem == .quickPath(quickPath.id),
                        isExpandable: false,
                        isExpanded: false,
                        isLoading: false,
                        onToggleExpansion: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("file-manager-sidebar-quick-path-\(quickPath.id.uuidString)")
                .contextMenu {
                    contextMenuButton(tr("Edit"), systemImage: ContextMenuIconCatalog.rename) {
                        onRenameQuickPath(quickPath)
                    }
                    contextMenuButton(tr("Delete"), systemImage: ContextMenuIconCatalog.delete, role: .destructive) {
                        onDeleteQuickPath(quickPath)
                    }
                }
            }

            if quickPaths.isEmpty {
                Text(tr("No quick paths yet."))
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }

    private var directoryTreeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionHeader(tr("Folders"))

                Spacer(minLength: 0)

                if remoteTreeRoot.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleRemoteTreeNodes) { node in
                    let accessibilityID = "file-manager-sidebar-directory-\(node.path.replacingOccurrences(of: "/", with: "_"))"
                    Button {
                        onSelectDirectory(node.path)
                    } label: {
                        FileManagerRemoteSidebarRow(
                            title: node.name,
                            systemImage: node.path == "/" ? "externaldrive.connected.to.line.below" : "folder.fill",
                            depth: node.depth,
                            isSelected: selectedItem == .directory(node.path),
                            isExpandable: true,
                            isExpanded: node.isExpanded,
                            isLoading: node.isLoading,
                            onToggleExpansion: {
                                onToggleDirectory(node.path)
                            }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(accessibilityID)
                    .contextMenu {
                        contextMenuButton(tr("Refresh"), systemImage: ContextMenuIconCatalog.refresh) {
                            onRefreshDirectory(node.path)
                        }
                        contextMenuButton(tr("Copy Path"), systemImage: ContextMenuIconCatalog.copyPath) {
                            onCopyDirectoryPath(node.path)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(VisualStyle.textSecondary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, 8)
    }
}

struct FileManagerRemoteSearchActivityTicker: View {
    var activities: [RemoteSearchActivity]

    @State private var activeIndex = 0

    private var currentActivity: RemoteSearchActivity? {
        guard !activities.isEmpty else { return nil }
        let safeIndex = min(max(activeIndex, 0), activities.count - 1)
        return activities[safeIndex]
    }

    var body: some View {
        Group {
            if let currentActivity {
                HStack(spacing: 6) {
                    Image(systemName: currentActivity.kind == .directory ? "folder" : "doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(currentActivity.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .id("\(currentActivity.id)-\(activeIndex)")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: activities.map(\.id).joined(separator: "|")) {
            activeIndex = 0
            guard activities.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activeIndex = (activeIndex + 1) % max(activities.count, 1)
                    }
                }
            }
        }
    }
}
