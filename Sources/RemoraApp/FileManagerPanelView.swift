import AppKit
import SwiftUI
import RemoraCore

struct FileManagerPanelView: View {
    static func parentDirectoryPath(for path: String) -> String? {
        let normalizedPath = NSString(string: path).standardizingPath
        guard normalizedPath != "/" else { return nil }

        let parentPath = (normalizedPath as NSString).deletingLastPathComponent
        return parentPath.isEmpty ? "/" : parentPath
    }

    private struct OperationToast: Identifiable, Equatable {
        var id = UUID()
        var message: String
    }

    private struct RemoteEditorTarget: Equatable {
        var path: String
        var size: Int64
        var modifiedAt: Date
    }

    private enum RemoteCreateKind {
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

    private enum RemoteSortColumn: String {
        case name
        case permission
        case date
        case size
        case kind
    }

    @ObservedObject var viewModel: FileTransferViewModel
    var quickPaths: [HostQuickPath] = []
    var onRunQuickPath: (HostQuickPath) -> Void = { _ in }
    var onManageQuickPaths: () -> Void = {}
    var onAddCurrentQuickPath: (String) -> Void = { _ in }
    var onRefreshRemote: () -> Void = {}
    var onEditDownloadPath: (() -> Void)?

    @State private var selectedRemotePaths: Set<String> = []
    @State private var hoveredRemotePath: String?
    @State private var hoveredTransferID: UUID?
    @State private var remotePathDraft = "/"
    @State private var lastTappedRemotePath: String?
    @State private var lastRemoteTapAt = Date.distantPast
    @State private var selectionAnchorRemotePath: String?
    @State private var isMoveSheetPresented = false
    @State private var moveTargetPath = "/"
    @State private var moveSourcePaths: [String] = []
    @State private var isRenameSheetPresented = false
    @State private var renameTargetPath: String?
    @State private var renameDraft = ""
    @State private var editorTarget: RemoteEditorTarget?
    @State private var logViewerTargetPath: String?
    @State private var propertiesTargetPath: String?
    @State private var permissionsEditorTargetPath: String?
    @State private var compressSourcePaths: [String] = []
    @State private var archiveNameDraft = ""
    @State private var selectedArchiveFormat: ArchiveFormat = .zip
    @State private var extractSourcePath: String?
    @State private var extractDestinationPath = "/"
    @State private var isArchiveOperationInFlight = false
    @State private var isUploadPanelPresented = false
    @State private var uploadTargetDirectory = "/"
    @State private var isCreateRemoteSheetPresented = false
    @State private var createRemoteKind: RemoteCreateKind = .file
    @State private var createRemoteTargetDirectory = "/"
    @State private var createRemoteNameDraft = ""
    @State private var isTransferQueueExpanded = false
    @State private var remoteSortColumn: RemoteSortColumn = .name
    @State private var isRemoteSortAscending = true
    @State private var activeRemoteDropDirectoryPath: String?
    @State private var isRemoteListDropTargeted = false
    @State private var operationToast: OperationToast?
    @State private var toastHideTask: Task<Void, Never>?

    private var selectedRemoteEntries: [RemoteFileEntry] {
        viewModel.remoteEntries.filter { selectedRemotePaths.contains($0.path) }
    }

    private var hasRetryableTransfers: Bool {
        viewModel.transferQueue.contains { $0.status == .failed || $0.status == .skipped }
    }

    private var abbreviatedLocalDirectoryPath: String {
        NSString(string: viewModel.localDirectoryURL.path).abbreviatingWithTildeInPath
    }

    private var currentDestinationDirectoryForPaste: String {
        viewModel.remoteDirectoryPath
    }

    private var parentRemoteDirectoryPath: String? {
        Self.parentDirectoryPath(for: viewModel.remoteDirectoryPath)
    }

    private struct TransferQueueSummary {
        var statusText: String
        var progress: Double
        var statusColor: Color
    }

    private var transferQueueSummary: TransferQueueSummary {
        let items = viewModel.transferQueue
        guard !items.isEmpty else {
            return TransferQueueSummary(statusText: tr("Idle"), progress: 0, statusColor: .secondary)
        }

        let hasRunning = items.contains { $0.status == .running || $0.status == .queued }
        let hasIssue = items.contains { $0.status == .failed || $0.status == .skipped }

        let statusText: String
        let statusColor: Color
        if hasRunning {
            statusText = tr("Transferring")
            statusColor = .orange
        } else if hasIssue {
            statusText = tr("Finished with Issues")
            statusColor = .red
        } else {
            statusText = tr("Completed")
            statusColor = .green
        }

        let aggregate = items.reduce(Double(0)) { partial, item in
            partial + transferProgressValue(for: item)
        }
        let progress = min(max(aggregate / Double(max(items.count, 1)), 0), 1)
        return TransferQueueSummary(statusText: statusText, progress: progress, statusColor: statusColor)
    }

    private var hasTransferTasks: Bool {
        !viewModel.transferQueue.isEmpty
    }

    private var activeRemoteDropTargetDirectoryPath: String? {
        guard isRemoteListDropTargeted else { return nil }
        return activeRemoteDropDirectoryPath ?? viewModel.remoteDirectoryPath
    }

    private var remoteDropHintText: String? {
        guard let target = activeRemoteDropTargetDirectoryPath else { return nil }
        return String(format: tr("Drop to upload to %@"), target)
    }

    private var sortedRemoteEntries: [RemoteFileEntry] {
        viewModel.remoteEntries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            let order: ComparisonResult = switch remoteSortColumn {
            case .name:
                lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .permission:
                permissionString(for: lhs).localizedCompare(permissionString(for: rhs))
            case .date:
                if lhs.modifiedAt == rhs.modifiedAt {
                    .orderedSame
                } else {
                    lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending
                }
            case .size:
                if lhs.size == rhs.size {
                    .orderedSame
                } else {
                    lhs.size < rhs.size ? .orderedAscending : .orderedDescending
                }
            case .kind:
                kindString(for: lhs).localizedCaseInsensitiveCompare(kindString(for: rhs))
            }

            if order == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            if isRemoteSortAscending {
                return order == .orderedAscending
            }
            return order == .orderedDescending
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            remotePanel
                .frame(minHeight: 150, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            let downloadPaths = FileManagerContextMenuPolicy.downloadablePaths(for: selectedRemotePaths)
                            performRemoteContextAction(
                                .download(paths: downloadPaths),
                                feedback: makeDownloadQueuedFeedback(count: downloadPaths.count)
                            )
                        } label: {
                            Label(tr("Download"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(FileManagerContextMenuPolicy.isBatchDownloadDisabled(selectedPaths: selectedRemotePaths))
                        .accessibilityIdentifier("file-manager-download")

                        Button(role: .destructive) {
                            let targets = Array(selectedRemotePaths)
                            performRemoteContextAction(
                                .delete(paths: targets),
                                feedback: makeDeleteFeedback(count: targets.count)
                            )
                            selectedRemotePaths.removeAll()
                            selectionAnchorRemotePath = nil
                        } label: {
                            Label(tr("Delete"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedRemotePaths.isEmpty)
                        .accessibilityIdentifier("file-manager-delete")

                        Button {
                            moveSourcePaths = Array(selectedRemotePaths)
                            moveTargetPath = viewModel.remoteDirectoryPath
                            isMoveSheetPresented = true
                        } label: {
                            Label(tr("Move To"), systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedRemotePaths.isEmpty)
                        .accessibilityIdentifier("file-manager-move")

                        Button(tr("Retry Failed")) {
                            viewModel.retryFailedTransfers()
                            showOperationToast(tr("Retrying failed transfers."))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!hasRetryableTransfers)
                        .accessibilityIdentifier("file-manager-retry-failed")

                        Button(tr("Paste")) {
                            performRemoteContextAction(
                                .paste(destinationDirectory: currentDestinationDirectoryForPaste),
                                feedback: makePasteFeedback(destination: currentDestinationDirectoryForPaste)
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!viewModel.canPaste(into: currentDestinationDirectoryForPaste))
                        .accessibilityIdentifier("file-manager-paste")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if hasTransferTasks, !isTransferQueueExpanded {
                    transferQueueCollapsedInlineControl
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.transferQueue.map(\.status))
        .animation(.easeInOut(duration: 0.2), value: isTransferQueueExpanded)
        .overlay(alignment: .bottomTrailing) {
            transferQueueFloatingOverlay
                .padding(8)
        }
        .overlay(alignment: .bottom) {
            if let operationToast {
                operationToastView(operationToast)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("file-manager-operation-toast")
            }
        }
        .onChange(of: hasTransferTasks) {
            if !hasTransferTasks {
                isTransferQueueExpanded = false
            }
        }
        .onAppear {
            remotePathDraft = viewModel.remoteDirectoryPath
        }
        .onChange(of: viewModel.remoteDirectoryPath) {
            remotePathDraft = viewModel.remoteDirectoryPath
            selectedRemotePaths.removeAll()
            selectionAnchorRemotePath = nil
            activeRemoteDropDirectoryPath = nil
            isRemoteListDropTargeted = false
        }
        .sheet(isPresented: $isMoveSheetPresented) {
            moveSheet
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            renameSheet
        }
        .sheet(isPresented: $isCreateRemoteSheetPresented) {
            createRemoteSheet
        }
        .sheet(
            isPresented: Binding(
                get: { editorTarget != nil },
                set: { isPresented in
                    if !isPresented {
                        editorTarget = nil
                    }
                }
            )
        ) {
            if let editorTarget {
                RemoteTextEditorSheet(
                    path: editorTarget.path,
                    loadOptions: RemoteTextDocumentLoadOptions(
                        knownSize: editorTarget.size,
                        knownModifiedAt: editorTarget.modifiedAt
                    ),
                    fileTransfer: viewModel
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { logViewerTargetPath != nil },
                set: { isPresented in
                    if !isPresented {
                        logViewerTargetPath = nil
                    }
                }
            )
        ) {
            if let logViewerTargetPath {
                RemoteLogViewerSheet(path: logViewerTargetPath, fileTransfer: viewModel)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { propertiesTargetPath != nil },
                set: { isPresented in
                    if !isPresented {
                        propertiesTargetPath = nil
                    }
                }
            )
        ) {
            if let propertiesTargetPath {
                RemoteFilePropertiesSheet(
                    path: propertiesTargetPath,
                    fileTransfer: viewModel,
                    initialAttributes: cachedRemoteAttributes(for: propertiesTargetPath)
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { permissionsEditorTargetPath != nil },
                set: { isPresented in
                    if !isPresented {
                        permissionsEditorTargetPath = nil
                    }
                }
            )
        ) {
            if let permissionsEditorTargetPath {
                RemotePermissionsEditorSheet(
                    path: permissionsEditorTargetPath,
                    fileTransfer: viewModel,
                    initialAttributes: cachedRemoteAttributes(for: permissionsEditorTargetPath)
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { !compressSourcePaths.isEmpty },
            set: { isPresented in
                if !isPresented {
                    compressSourcePaths = []
                    archiveNameDraft = ""
                }
            }
        )) {
            RemoteCompressSheet(
                sourcePaths: compressSourcePaths,
                archiveName: $archiveNameDraft,
                format: $selectedArchiveFormat,
                isBusy: isArchiveOperationInFlight,
                progress: viewModel.archiveOperationProgress,
                statusText: viewModel.archiveOperationStatusText,
                onConfirm: commitCompress
            )
        }
        .sheet(isPresented: Binding(
            get: { extractSourcePath != nil },
            set: { isPresented in
                if !isPresented {
                    extractSourcePath = nil
                }
            }
        )) {
            if let extractSourcePath {
                RemoteExtractSheet(
                    archivePath: extractSourcePath,
                    destinationPath: $extractDestinationPath,
                    isBusy: isArchiveOperationInFlight,
                    progress: viewModel.archiveOperationProgress,
                    statusText: viewModel.archiveOperationStatusText,
                    onConfirm: commitExtract
                )
            }
        }
        .onDisappear {
            toastHideTask?.cancel()
            toastHideTask = nil
            operationToast = nil
        }
    }

    private var remotePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            remoteToolbar
            remoteListHeader

            ScrollViewReader { proxy in
                List {
                    ForEach(Array(sortedRemoteEntries.enumerated()), id: \.element.path) { rowIndex, entry in
                        let isSelected = selectedRemotePaths.contains(entry.path)
                        let isDropTarget = activeRemoteDropDirectoryPath == entry.path
                        remoteListRow(entry, isDropTarget: isDropTarget)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            Rectangle()
                                .fill(
                                    isSelected
                                        ? Color.accentColor
                                        : (
                                            activeRemoteDropDirectoryPath == entry.path
                                                ? Color.accentColor.opacity(0.24)
                                                : rowBackgroundColor(rowIndex: rowIndex, isHovered: hoveredRemotePath == entry.path)
                                        )
                                )
                        )
                        .scaleEffect(isDropTarget ? 1.012 : 1.0, anchor: .center)
                        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isDropTarget)
                        .contentShape(Rectangle())
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .tag(entry.path)
                        .accessibilityIdentifier(remoteRowIdentifier(entry.path))
                        .onTapGesture {
                            handleRemoteRowTap(entry)
                        }
                        .onHover { hovering in
                            hoveredRemotePath = hovering ? entry.path : nil
                        }
                        .dropDestination(for: URL.self) { items, _ in
                            handleRemoteDrop(items: items, targetEntry: entry)
                        } isTargeted: { isTargeted in
                            updateRemoteDropTarget(for: entry, isTargeted: isTargeted)
                        }
                        .contextMenu {
                            rowContextMenu(for: entry)
                        }
                    }
                }
                .onChange(of: viewModel.remoteDirectoryPath) {
                    guard let firstPath = sortedRemoteEntries.first?.path else {
                        return
                    }
                    DispatchQueue.main.async {
                        proxy.scrollTo(firstPath, anchor: .top)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scrollContentBackground(.hidden)
                .background(VisualStyle.rightPanelBackground)
                .listStyle(.plain)
                .accessibilityIdentifier("file-manager-remote-list")
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isRemoteListDropTargeted && activeRemoteDropDirectoryPath == nil
                                ? Color.accentColor.opacity(0.85)
                                : Color.clear,
                            lineWidth: 2
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if let remoteDropHintText {
                        Text(remoteDropHintText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(VisualStyle.overlayBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                            )
                            .padding(8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .accessibilityIdentifier("file-manager-remote-drop-hint")
                    }
                }
                .dropDestination(for: URL.self) { items, _ in
                    handleRemoteDrop(items: items, targetEntry: nil)
                } isTargeted: { isTargeted in
                    isRemoteListDropTargeted = isTargeted
                    if !isTargeted {
                        activeRemoteDropDirectoryPath = nil
                    }
                }
                .contextMenu {
                    panelContextMenu
                }
                .overlay(alignment: .center) {
                    if viewModel.isRemoteLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(tr("Loading directory..."))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(VisualStyle.overlayBackground)
                        )
                        .padding(16)
                        .accessibilityIdentifier("file-manager-remote-loading")
                    } else if sortedRemoteEntries.isEmpty,
                              let message = viewModel.remoteLoadErrorMessage,
                              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(tr("Failed to load remote directory"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(VisualStyle.overlayBackground)
                        )
                        .padding(16)
                        .accessibilityIdentifier("file-manager-remote-error")
                    }
                }
            }
        }
    }

    private var remoteListHeader: some View {
        HStack(spacing: 10) {
            sortHeaderButton(tr("Name"), column: .name, width: nil, alignment: .leading)
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Permission"), column: .permission, width: 120, alignment: .leading)
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Date"), column: .date, width: 170, alignment: .leading)
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Size"), column: .size, width: 90, alignment: .trailing)
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Kind"), column: .kind, width: 90, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(VisualStyle.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sortHeaderButton(
        _ title: String,
        column: RemoteSortColumn,
        width: CGFloat?,
        alignment: Alignment
    ) -> some View {
        Button {
            if remoteSortColumn == column {
                isRemoteSortAscending.toggle()
            } else {
                remoteSortColumn = column
                isRemoteSortAscending = true
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }
                Text(title)
                    .lineLimit(1)
                if remoteSortColumn == column {
                    Image(systemName: isRemoteSortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                if alignment != .trailing {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .foregroundStyle(VisualStyle.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width, alignment: alignment)
        .contentShape(Rectangle())
        .accessibilityIdentifier("file-manager-sort-\(column.rawValue)")
    }

    private func remoteListRow(_ entry: RemoteFileEntry, isDropTarget: Bool = false) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .foregroundStyle(remoteSecondaryTextColor(for: entry.path))
                Text(entry.name)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(remotePrimaryTextColor(for: entry.path))
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(permissionString(for: entry))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(remoteSecondaryTextColor(for: entry.path))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(remoteDateText(for: entry.modifiedAt))
                .font(.system(size: 13))
                .foregroundStyle(remoteSecondaryTextColor(for: entry.path))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            Text(ByteSizeFormatter.format(entry.size))
                .font(.system(size: 13))
                .foregroundStyle(remoteSecondaryTextColor(for: entry.path))
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)

            Text(kindString(for: entry))
                .font(.system(size: 13))
                .foregroundStyle(remoteSecondaryTextColor(for: entry.path))
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
    }

    private static let remoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func remoteDateText(for date: Date) -> String {
        let formatter = Self.remoteDateFormatter
        formatter.locale = AppLanguageMode.preferredLocale()
        return formatter.string(from: date)
    }

    private func permissionString(for entry: RemoteFileEntry) -> String {
        guard let permission = entry.permissions else {
            return entry.isDirectory ? "d---------" : "----------"
        }
        return permissionString(mode: permission, isDirectory: entry.isDirectory)
    }

    private func permissionString(mode: UInt16, isDirectory: Bool) -> String {
        let prefix = isDirectory ? "d" : "-"
        let owner = permissionTriad((mode >> 6) & 0b111)
        let group = permissionTriad((mode >> 3) & 0b111)
        let other = permissionTriad(mode & 0b111)
        return "\(prefix)\(owner)\(group)\(other)"
    }

    private func permissionTriad(_ value: UInt16) -> String {
        let readable = (value & 0b100) != 0 ? "r" : "-"
        let writable = (value & 0b010) != 0 ? "w" : "-"
        let executable = (value & 0b001) != 0 ? "x" : "-"
        return "\(readable)\(writable)\(executable)"
    }

    private func kindString(for entry: RemoteFileEntry) -> String {
        entry.isDirectory ? tr("Folder") : tr("File")
    }

    private func cachedRemoteAttributes(for path: String) -> RemoteFileAttributes? {
        guard let entry = viewModel.remoteEntries.first(where: { $0.path == path }) else {
            return nil
        }
        return RemoteFileAttributes(
            permissions: entry.permissions,
            owner: entry.owner,
            group: entry.group,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            isDirectory: entry.isDirectory
        )
    }

    private var remoteToolbar: some View {
        HStack(spacing: 8) {
            toolbarIconButton(
                "chevron.backward",
                accessibilityIdentifier: "file-manager-back",
                helpText: tr("Back"),
                disabled: !viewModel.canNavigateRemoteBack
            ) {
                viewModel.navigateRemoteBack()
            }

            toolbarIconButton(
                "chevron.forward",
                accessibilityIdentifier: "file-manager-forward",
                helpText: tr("Forward"),
                disabled: !viewModel.canNavigateRemoteForward
            ) {
                viewModel.navigateRemoteForward()
            }

            toolbarIconButton(
                "chevron.up",
                accessibilityIdentifier: "file-manager-up",
                helpText: tr("Go to Parent Directory"),
                disabled: parentRemoteDirectoryPath == nil
            ) {
                navigateToParentDirectory()
            }

            toolbarIconButton(
                "house",
                accessibilityIdentifier: "file-manager-root",
                helpText: tr("Go to Root"),
                disabled: viewModel.remoteDirectoryPath == "/"
            ) {
                navigateToRoot()
            }

            toolbarIconButton(
                "arrow.clockwise",
                accessibilityIdentifier: "file-manager-refresh",
                helpText: tr("Refresh"),
                disabled: false
            ) {
                onRefreshRemote()
            }

            Menu {
                if quickPaths.isEmpty {
                    Text(tr("No quick paths"))
                } else {
                    ForEach(quickPaths) { quickPath in
                        Button(quickPath.name) {
                            onRunQuickPath(quickPath)
                        }
                    }
                }
                Divider()
                Button(tr("Add current path")) {
                    onAddCurrentQuickPath(viewModel.remoteDirectoryPath)
                }
                Button(tr("Manage quick paths")) {
                    onManageQuickPaths()
                }
            } label: {
                toolbarIconChrome(
                    "bookmark.circle",
                    disabled: false
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(tr("Open quick paths"))
            .accessibilityIdentifier("file-manager-quick-paths")

            TextField("/path/to/dir", text: $remotePathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(minWidth: 180, maxWidth: .infinity)
                .layoutPriority(1)
                .onSubmit {
                    jumpToRemotePath()
                }
                .accessibilityIdentifier("file-manager-path-field")

            toolbarIconButton(
                "arrow.right.circle",
                accessibilityIdentifier: "file-manager-go",
                helpText: tr("Go"),
                disabled: false
            ) {
                jumpToRemotePath()
            }

            Toggle(tr("Sync Terminal"), isOn: $viewModel.isTerminalDirectorySyncEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .accessibilityIdentifier("file-manager-sync-toggle")
                .fixedSize()
        }
    }

    private var transferQueueFloatingOverlay: some View {
        Group {
            if hasTransferTasks, isTransferQueueExpanded {
                transferQueueExpandedPanel
            }
        }
    }

    private var transferQueueCollapsedInlineControl: some View {
        Button {
            isTransferQueueExpanded = true
        } label: {
            ProgressView(value: transferQueueSummary.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(width: 150)
                .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("file-manager-transfer-collapsed")
    }

    private var transferQueueExpandedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("Transfer Queue"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(transferQueueSummary.progress * 100))%")
                    .font(.caption.monospaced())
                    .foregroundStyle(VisualStyle.textSecondary)
                Button {
                    isTransferQueueExpanded = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help(tr("Collapse Transfer Queue"))
                .accessibilityIdentifier("file-manager-transfer-collapse")
            }

            HStack(spacing: 8) {
                Text("\(tr("Save To:")) \(abbreviatedLocalDirectoryPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)

                Button {
                    onEditDownloadPath?()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help(tr("Edit download directory"))
                .accessibilityIdentifier("file-manager-open-download-settings")

                Spacer()

                Button(tr("Open Folder")) {
                    revealInFinder(path: viewModel.localDirectoryURL.path)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier("file-manager-open-download-folder")
            }

            ProgressView(value: transferQueueSummary.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)

            if viewModel.transferQueue.isEmpty {
                Text(tr("No transfer tasks"))
                    .monoMetaStyle()
            } else {
                List(viewModel.transferQueue) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(tr(item.direction.rawValue))
                                .font(.caption.monospaced())
                                .frame(width: 70, alignment: .leading)
                                .foregroundStyle(VisualStyle.textSecondary)
                            Text(item.name)
                                .lineLimit(1)
                                .foregroundStyle(VisualStyle.textPrimary)
                            Spacer()
                            if item.direction == .download, item.status == .success {
                                Button {
                                    revealInFinder(path: item.destinationPath)
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled(!FileManager.default.fileExists(atPath: item.destinationPath))
                                .help(tr("Reveal Downloaded File"))
                                .accessibilityIdentifier("file-manager-transfer-reveal-\(item.id.uuidString)")
                            }
                            Text(transferStatusText(for: item))
                                .font(.caption.monospaced())
                                .foregroundStyle(statusColor(item.status))
                                .lineLimit(1)
                        }

                        ProgressView(value: transferProgressValue(for: item))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hoveredTransferID == item.id ? VisualStyle.leftInteractiveBackground : Color.clear)
                    )
                    .onHover { hovering in
                        hoveredTransferID = hovering ? item.id : nil
                    }
                    .contextMenu {
                        transferContextMenu(for: item)
                    }
                }
                .frame(minHeight: 100, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scrollContentBackground(.hidden)
                .background(VisualStyle.rightPanelBackground)
                .listStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VisualStyle.rightPanelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
        .accessibilityIdentifier("file-manager-transfer-expanded")
    }

    @ViewBuilder
    private var panelContextMenu: some View {
        Button(tr("Refresh")) {
            viewModel.performContextAction(.refresh)
        }

        Divider()

        Button(tr("New File")) {
            beginCreateRemote(kind: .file, in: viewModel.remoteDirectoryPath)
        }

        Button(tr("New Folder")) {
            beginCreateRemote(kind: .directory, in: viewModel.remoteDirectoryPath)
        }

        Divider()

        if viewModel.canPaste(into: viewModel.remoteDirectoryPath) {
            Button(tr("Paste")) {
                performRemoteContextAction(
                    .paste(destinationDirectory: viewModel.remoteDirectoryPath),
                    feedback: makePasteFeedback(destination: viewModel.remoteDirectoryPath)
                )
            }
        }

        Button(tr("Upload To Current Directory")) {
            presentUploadPanel(targetDirectory: viewModel.remoteDirectoryPath)
        }

        if !selectedRemotePaths.isEmpty {
            Divider()

            Button(tr("Compress Selected")) {
                beginCompress(paths: Array(selectedRemotePaths))
            }

            if selectedRemotePaths.count == 1,
               let selectedPath = selectedRemotePaths.first,
               let selectedEntry = viewModel.remoteEntries.first(where: { $0.path == selectedPath }),
               !selectedEntry.isDirectory,
               ArchiveFormat.extractFormat(for: selectedEntry.name) != nil
            {
                Button(tr("Extract To")) {
                    beginExtract(path: selectedEntry.path, destinationDirectory: viewModel.remoteDirectoryPath)
                }
            }
        }
    }

    @ViewBuilder
    private func rowContextMenu(for entry: RemoteFileEntry) -> some View {
        Button(tr("Refresh")) {
            viewModel.performContextAction(.refresh)
        }

        Divider()

        Button(tr("Delete"), role: .destructive) {
            performRemoteContextAction(
                .delete(paths: [entry.path]),
                feedback: makeDeleteFeedback(count: 1)
            )
            selectedRemotePaths.remove(entry.path)
            if selectionAnchorRemotePath == entry.path {
                selectionAnchorRemotePath = nil
            }
        }

        Button(tr("Rename")) {
            beginRename(path: entry.path)
        }

        Button(tr("Copy")) {
            performRemoteContextAction(
                .copy(paths: [entry.path]),
                feedback: makeCopyFeedback(count: 1)
            )
        }

        Button(tr("Cut")) {
            performRemoteContextAction(
                .cut(paths: [entry.path]),
                feedback: makeCutFeedback(count: 1)
            )
        }

        if viewModel.canPaste(into: entry.isDirectory ? entry.path : viewModel.remoteDirectoryPath) {
            Button(tr("Paste")) {
                let destination = entry.isDirectory ? entry.path : viewModel.remoteDirectoryPath
                performRemoteContextAction(
                    .paste(destinationDirectory: destination),
                    feedback: makePasteFeedback(destination: destination)
                )
            }
        }

        if entry.isDirectory {
            Button(tr("New File Here")) {
                beginCreateRemote(kind: .file, in: entry.path)
            }

            Button(tr("New Folder Here")) {
                beginCreateRemote(kind: .directory, in: entry.path)
            }
        }

        let selectedDownloadPaths = FileManagerContextMenuPolicy.downloadablePaths(for: selectedRemotePaths)
        let shouldSplitDownloadActions = selectedDownloadPaths.count > 1
            && selectedRemotePaths.contains(entry.path)

        if shouldSplitDownloadActions {
            Button(tr("Download Current")) {
                performRemoteContextAction(
                    .download(paths: [entry.path]),
                    feedback: makeDownloadQueuedFeedback(count: 1)
                )
            }
            .disabled(FileManagerContextMenuPolicy.isDownloadDisabled(isDirectory: entry.isDirectory))

            Button("\(tr("Download Selected")) (\(selectedDownloadPaths.count))") {
                performRemoteContextAction(
                    .download(paths: selectedDownloadPaths),
                    feedback: makeDownloadQueuedFeedback(count: selectedDownloadPaths.count)
                )
            }
            .disabled(selectedDownloadPaths.isEmpty)
        } else {
            Button(tr("Download")) {
                performRemoteContextAction(
                    .download(paths: [entry.path]),
                    feedback: makeDownloadQueuedFeedback(count: 1)
                )
            }
            .disabled(FileManagerContextMenuPolicy.isDownloadDisabled(isDirectory: entry.isDirectory))
        }

        Button(tr("Move To")) {
            moveSourcePaths = [entry.path]
            moveTargetPath = viewModel.remoteDirectoryPath
            isMoveSheetPresented = true
        }

        Button(tr("Compress")) {
            beginCompress(paths: [entry.path])
        }

        Divider()

        if !entry.isDirectory {
            Button(tr("Live View")) {
                beginViewLog(entry)
            }

            Button(tr("Edit")) {
                beginEdit(entry)
            }
        }

        Button(tr("Copy Path")) {
            copyToPasteboard(entry.path)
        }

        Button(tr("Copy Name")) {
            copyToPasteboard(entry.name)
        }

        Button(tr("Properties")) {
            propertiesTargetPath = entry.path
        }

        if !entry.isDirectory, ArchiveFormat.extractFormat(for: entry.name) != nil {
            Button(tr("Extract To")) {
                beginExtract(path: entry.path, destinationDirectory: viewModel.remoteDirectoryPath)
            }
        }

        Button(tr("Edit Permissions")) {
            permissionsEditorTargetPath = entry.path
        }

        if entry.isDirectory {
            Divider()
            Button(tr("Upload To Current Directory")) {
                presentUploadPanel(targetDirectory: entry.path)
            }
        }
    }

    private func transferProgressValue(for item: TransferItem) -> Double {
        if let fraction = item.fractionCompleted {
            return min(max(fraction, 0), 1)
        }

        switch item.status {
        case .success, .failed, .skipped:
            return 1
        case .running:
            return 0.1
        case .queued:
            return 0
        }
    }

    private func transferStatusText(for item: TransferItem) -> String {
        let localizedStatus = tr(item.status.rawValue)
        switch item.status {
        case .failed, .skipped:
            if let message = item.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(localizedStatus): \(message)"
            }
            return localizedStatus
        default:
            return localizedStatus
        }
    }

    private func statusColor(_ status: TransferStatus) -> Color {
        switch status {
        case .queued:
            return .secondary
        case .running:
            return .orange
        case .success:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .gray
        }
    }

    @ViewBuilder
    private func toolbarIconChrome(
        _ systemImage: String,
        disabled: Bool
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 14, height: 14)
            .foregroundStyle(disabled ? VisualStyle.textTertiary : VisualStyle.textSecondary)
            .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(disabled ? 0.72 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(disabled ? 0.35 : 0.7), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func toolbarIconButton(
        _ systemImage: String,
        accessibilityIdentifier: String,
        helpText: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarIconChrome(
                systemImage,
                disabled: disabled
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .disabled(disabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func handleRemoteRowTap(_ entry: RemoteFileEntry) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let orderedPaths = sortedRemoteEntries.map(\.path)
        let result = RemoteListSelection.applyClick(
            currentSelection: selectedRemotePaths,
            anchorPath: selectionAnchorRemotePath,
            orderedPaths: orderedPaths,
            clickedPath: entry.path,
            modifiers: modifiers
        )
        selectedRemotePaths = result.selectedPaths
        selectionAnchorRemotePath = result.anchorPath

        let now = Date()
        if entry.isDirectory,
           lastTappedRemotePath == entry.path,
           now.timeIntervalSince(lastRemoteTapAt) < 0.32
        {
            viewModel.openRemote(entry)
            selectedRemotePaths.removeAll()
            selectionAnchorRemotePath = nil
            lastTappedRemotePath = nil
            lastRemoteTapAt = .distantPast
            return
        }

        if !entry.isDirectory,
           lastTappedRemotePath == entry.path,
           now.timeIntervalSince(lastRemoteTapAt) < 0.32
        {
            showOperationToast(tr("To edit this file, right-click it and choose Edit."))
            lastTappedRemotePath = nil
            lastRemoteTapAt = .distantPast
            return
        }

        lastTappedRemotePath = entry.path
        lastRemoteTapAt = now
    }

    private func jumpToRemotePath() {
        viewModel.navigateRemote(to: remotePathDraft)
        selectedRemotePaths.removeAll()
        selectionAnchorRemotePath = nil
    }

    private func navigateToRoot() {
        viewModel.navigateRemote(to: "/")
        selectedRemotePaths.removeAll()
        selectionAnchorRemotePath = nil
    }

    private func navigateToParentDirectory() {
        guard let parentRemoteDirectoryPath else { return }
        viewModel.navigateRemote(to: parentRemoteDirectoryPath)
        selectedRemotePaths.removeAll()
        selectionAnchorRemotePath = nil
    }

    private func beginRename(path: String) {
        renameTargetPath = path
        renameDraft = URL(fileURLWithPath: path).lastPathComponent
        isRenameSheetPresented = true
    }

    private func beginEdit(_ entry: RemoteFileEntry) {
        guard !entry.isDirectory else { return }
        if entry.size > Int64(FileTransferViewModel.maxInlineEditableTextDocumentBytes) {
            presentLargeFileEditPrompt(for: entry)
            return
        }
        editorTarget = RemoteEditorTarget(
            path: entry.path,
            size: entry.size,
            modifiedAt: entry.modifiedAt
        )
    }

    private func beginViewLog(_ entry: RemoteFileEntry) {
        guard !entry.isDirectory else { return }
        logViewerTargetPath = entry.path
    }

    private func presentLargeFileEditPrompt(for entry: RemoteFileEntry) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Large file detected")
        alert.informativeText = String(
            format: tr("This file is too large for in-app editing (%@ > %@). Download it and open locally to avoid high memory usage."),
            ByteSizeFormatter.format(entry.size),
            ByteSizeFormatter.format(Int64(FileTransferViewModel.maxInlineEditableTextDocumentBytes))
        )
        alert.addButton(withTitle: tr("Download"))
        alert.addButton(withTitle: tr("Cancel"))

        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.performContextAction(.download(paths: [entry.path]))
            isTransferQueueExpanded = true
        }
    }

    private func commitRename() {
        let sourcePath = renameTargetPath
        isRenameSheetPresented = false
        renameTargetPath = nil
        guard let sourcePath else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        performRemoteContextAction(
            .rename(path: sourcePath, newName: newName),
            feedback: String(format: tr("Renamed to %@."), newName)
        )
    }

    private func beginCreateRemote(kind: RemoteCreateKind, in directoryPath: String) {
        createRemoteKind = kind
        createRemoteTargetDirectory = directoryPath
        createRemoteNameDraft = kind.defaultName
        isCreateRemoteSheetPresented = true
    }

    private func beginCompress(paths: [String]) {
        let normalized = Array(Set(paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !normalized.isEmpty else { return }
        compressSourcePaths = normalized
        let baseName = normalized.count == 1
            ? URL(fileURLWithPath: normalized[0]).lastPathComponent
            : tr("Archive")
        archiveNameDraft = ArchiveSupport.defaultArchiveName(for: baseName, format: selectedArchiveFormat)
    }

    private func commitCompress() {
        let sourcePaths = compressSourcePaths
        let archiveName = archiveNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourcePaths.isEmpty, !archiveName.isEmpty else { return }
        isArchiveOperationInFlight = true
        Task {
            defer {
                Task { @MainActor in
                    isArchiveOperationInFlight = false
                }
            }
            do {
                try await viewModel.compressRemoteEntries(
                    paths: sourcePaths,
                    archiveName: archiveName,
                    format: selectedArchiveFormat,
                    destinationDirectory: viewModel.remoteDirectoryPath
                )
                await MainActor.run {
                    showOperationToast(tr("Archive created."))
                    compressSourcePaths = []
                    archiveNameDraft = ""
                }
            } catch {
                await MainActor.run {
                    showOperationToast(error.localizedDescription)
                }
            }
        }
    }

    private func beginExtract(path: String, destinationDirectory: String) {
        extractSourcePath = path
        extractDestinationPath = destinationDirectory
    }

    private func commitExtract() {
        guard let sourcePath = extractSourcePath else { return }
        let destinationPath = extractDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destinationPath.isEmpty else { return }
        isArchiveOperationInFlight = true
        Task {
            defer {
                Task { @MainActor in
                    isArchiveOperationInFlight = false
                }
            }
            do {
                try await viewModel.extractRemoteArchive(path: sourcePath, into: destinationPath)
                await MainActor.run {
                    showOperationToast(tr("Archive extracted."))
                    extractSourcePath = nil
                }
            } catch {
                await MainActor.run {
                    showOperationToast(error.localizedDescription)
                }
            }
        }
    }

    private func commitCreateRemote() {
        let trimmedName = createRemoteNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        switch createRemoteKind {
        case .file:
            viewModel.createRemoteFile(named: trimmedName, in: createRemoteTargetDirectory)
        case .directory:
            viewModel.createRemoteDirectory(named: trimmedName, in: createRemoteTargetDirectory)
        }
        showOperationToast(String(format: tr("Created \"%@\"."), trimmedName))
        selectedRemotePaths.removeAll()
        selectionAnchorRemotePath = nil
        isCreateRemoteSheetPresented = false
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    @ViewBuilder
    private func transferContextMenu(for item: TransferItem) -> some View {
        if item.direction == .download {
            Button(tr("Copy Local Path")) {
                copyToPasteboard(item.destinationPath)
            }

            if FileManager.default.fileExists(atPath: item.destinationPath) {
                Button(tr("Reveal in Finder")) {
                    revealInFinder(path: item.destinationPath)
                }
            }
        } else {
            Button(tr("Copy Destination Path")) {
                copyToPasteboard(item.destinationPath)
            }
        }
    }

    private func presentUploadPanel(targetDirectory: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false

        if panel.runModal() == .OK {
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            let acceptedURLs = RemoteDropRouting.acceptedLocalDropURLs(urls)
            guard !acceptedURLs.isEmpty else { return }
            viewModel.enqueueUpload(localFileURLs: acceptedURLs, toRemoteDirectory: targetDirectory)
            showOperationToast(
                String(format: tr("Queued %d item(s) for upload to %@."), acceptedURLs.count, targetDirectory)
            )
        }
    }

    private func handleRemoteDrop(items: [URL], targetEntry: RemoteFileEntry?) -> Bool {
        let acceptedItems = RemoteDropRouting.acceptedLocalDropURLs(items)
        guard !acceptedItems.isEmpty else { return false }

        let destination = RemoteDropRouting.resolveUploadTargetDirectory(
            dropTargetEntry: targetEntry,
            currentRemoteDirectory: viewModel.remoteDirectoryPath
        )
        viewModel.enqueueUpload(localFileURLs: acceptedItems, toRemoteDirectory: destination)
        showOperationToast(
            String(format: tr("Queued %d item(s) for upload to %@."), acceptedItems.count, destination)
        )
        activeRemoteDropDirectoryPath = nil
        isRemoteListDropTargeted = false
        return true
    }

    private func updateRemoteDropTarget(for entry: RemoteFileEntry, isTargeted: Bool) {
        guard entry.isDirectory else { return }
        if isTargeted {
            isRemoteListDropTargeted = true
            activeRemoteDropDirectoryPath = entry.path
            return
        }
        if activeRemoteDropDirectoryPath == entry.path {
            activeRemoteDropDirectoryPath = nil
        }
    }

    private var createRemoteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(createRemoteKind.title)
                .font(.headline)

            Text(tr("Directory"))
                .font(.subheadline)
                .foregroundStyle(VisualStyle.textSecondary)

            Text(createRemoteTargetDirectory)
                .font(.caption.monospaced())
                .lineLimit(1)

            TextField(tr("Name"), text: $createRemoteNameDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("file-manager-create-name")

            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) {
                    isCreateRemoteSheetPresented = false
                }
                Button(tr("Create")) {
                    commitCreateRemote()
                }
                .buttonStyle(.borderedProminent)
                .disabled(createRemoteNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("file-manager-create-confirm")
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Rename"))
                .font(.headline)

            TextField(tr("New name"), text: $renameDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) {
                    isRenameSheetPresented = false
                }
                Button(tr("Save")) {
                    commitRename()
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var moveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Move Selected Files"))
                .font(.headline)

            Text(tr("Destination Directory"))
                .font(.subheadline)
                .foregroundStyle(VisualStyle.textSecondary)

            TextField("/target/path", text: $moveTargetPath)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            HStack(spacing: 8) {
                Text(tr("Conflict"))
                    .font(.subheadline.weight(.semibold))

                Picker(tr("Conflict"), selection: $viewModel.conflictStrategy) {
                    ForEach(TransferConflictStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 140)
                .labelsHidden()
                .accessibilityIdentifier("file-manager-move-conflict")
            }

            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) {
                    moveSourcePaths.removeAll()
                    isMoveSheetPresented = false
                }
                Button(tr("Move")) {
                    viewModel.moveRemoteEntries(
                        paths: moveSourcePaths,
                        toDirectory: moveTargetPath
                    )
                    showOperationToast(
                        String(format: tr("Moved %d item(s) to %@."), moveSourcePaths.count, moveTargetPath)
                    )
                    moveSourcePaths.removeAll()
                    selectedRemotePaths.removeAll()
                    selectionAnchorRemotePath = nil
                    isMoveSheetPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func rowBackgroundColor(rowIndex: Int, isHovered: Bool) -> Color {
        if isHovered {
            return Color(nsColor: NSColor.alternatingContentBackgroundColors.first ?? .controlBackgroundColor)
                .opacity(0.9)
        }
        let stripe = rowIndex.isMultiple(of: 2)
            ? NSColor.controlBackgroundColor
            : NSColor.alternatingContentBackgroundColors.first ?? .controlBackgroundColor
        return Color(nsColor: stripe)
    }

    private func remotePrimaryTextColor(for path: String) -> Color {
        isPathActiveForSelectionVisual(path)
            ? Color(nsColor: .alternateSelectedControlTextColor)
            : VisualStyle.textPrimary
    }

    private func remoteSecondaryTextColor(for path: String) -> Color {
        isPathActiveForSelectionVisual(path)
            ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8)
            : VisualStyle.textSecondary
    }

    private func isPathActiveForSelectionVisual(_ path: String) -> Bool {
        selectedRemotePaths.contains(path) || activeRemoteDropDirectoryPath == path
    }

    private func remoteRowIdentifier(_ path: String) -> String {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        return "file-manager-remote-row\(sanitized)"
    }

    private func performRemoteContextAction(_ action: RemoteContextAction, feedback: String? = nil) {
        viewModel.performContextAction(action)
        if let feedback {
            showOperationToast(feedback)
        }
    }

    private func showOperationToast(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        toastHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            operationToast = OperationToast(message: trimmed)
        }
        toastHideTask = Task { @MainActor [trimmed] in
            _ = trimmed
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                operationToast = nil
            }
            toastHideTask = nil
        }
    }

    @ViewBuilder
    private func operationToastView(_ toast: OperationToast) -> some View {
        Text(toast.message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(VisualStyle.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VisualStyle.overlayBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(VisualStyle.borderSoft, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
    }

    private func makeCopyFeedback(count: Int) -> String {
        String(format: tr("Copied %d item(s)."), max(count, 1))
    }

    private func makeCutFeedback(count: Int) -> String {
        String(format: tr("Cut %d item(s)."), max(count, 1))
    }

    private func makeDeleteFeedback(count: Int) -> String {
        String(format: tr("Deleted %d item(s)."), max(count, 1))
    }

    private func makeDownloadQueuedFeedback(count: Int) -> String {
        String(format: tr("Queued %d item(s) for download."), max(count, 1))
    }

    private func makePasteFeedback(destination: String) -> String {
        String(format: tr("Pasted into %@."), destination)
    }
}
