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

    private struct RemoteListRowItem: Identifiable {
        var path: String
        var displayName: String
        var name: String
        var parentPath: String
        var size: Int64?
        var permissions: UInt16?
        var modifiedAt: Date?
        var isDirectory: Bool

        var id: String { path }
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
    @State private var transferQueueOverlayState = TransferQueueOverlayState()
    @State private var remoteSortColumn: RemoteSortColumn = .name
    @State private var isRemoteSortAscending = true
    @State private var activeRemoteDropDirectoryPath: String?
    @State private var isRemoteListDropTargeted = false
    @State private var operationToast: OperationToast?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var isRemoteSearchPresented = true
    @State private var remoteSearchDraft = ""
    @State private var remoteSearchScope: RemoteSearchScope = .currentDirectory
    @State private var remoteSearchDebounceTask: Task<Void, Never>?
    @FocusState private var isRemoteSearchFieldFocused: Bool

    private var selectedRemoteEntries: [RemoteFileEntry] {
        viewModel.remoteEntries.filter { selectedRemotePaths.contains($0.path) }
    }

    private var isShowingSearchResults: Bool {
        viewModel.remoteSearchStatus.hasActiveQuery
    }

    private var hasRetryableTransfers: Bool {
        viewModel.transferQueue.contains { $0.status == .failed || $0.status == .skipped || $0.status == .stopped }
    }

    private var hasStoppableTransfers: Bool {
        viewModel.transferQueue.contains { $0.status == .queued || $0.status == .running }
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
        let snapshot = TransferQueueAggregateSnapshot.resolve(
            items: viewModel.transferQueue,
            currentBatchID: viewModel.currentTransferBatchID,
            runningFallbackProgress: 0.1
        )
        guard snapshot.status != .idle else {
            return TransferQueueSummary(statusText: tr("Idle"), progress: 0, statusColor: .secondary)
        }

        let statusText: String = switch snapshot.status {
        case .idle:
            tr("Idle")
        case .transferring:
            tr("Transferring")
        case .finishedWithIssues:
            tr("Finished with Issues")
        case .completed:
            tr("Completed")
        }
        let statusColor: Color = switch snapshot.status {
        case .idle:
            .secondary
        case .transferring:
            .orange
        case .finishedWithIssues:
            .red
        case .completed:
            .green
        }

        return TransferQueueSummary(statusText: statusText, progress: snapshot.progress, statusColor: statusColor)
    }

    private var hasTransferTasks: Bool {
        !viewModel.transferQueue.isEmpty
    }

    private var activeRemoteDropTargetDirectoryPath: String? {
        guard isRemoteListDropTargeted else { return nil }
        return activeRemoteDropDirectoryPath ?? viewModel.remoteDirectoryPath
    }

    private var remoteSearchRootPath: String {
        remoteSearchScope == .entireServer ? "/" : viewModel.remoteDirectoryPath
    }

    private var displayedRemoteItems: [RemoteListRowItem] {
        if isShowingSearchResults {
            return viewModel.remoteSearchResults.map(makeRemoteListRowItem(from:))
        }
        return sortedRemoteEntries.map(makeRemoteListRowItem(from:))
    }

    private var remoteDropHintText: String? {
        guard let target = activeRemoteDropTargetDirectoryPath else { return nil }
        return String(format: tr("Drop to upload to %@"), target)
    }

    private var sortedRemoteEntries: [RemoteFileEntry] {
        viewModel.remoteEntries.sorted(by: { lhs, rhs in
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
        })
    }

    var body: some View {
        VStack(spacing: 8) {
            remotePanel
                .frame(minHeight: 150, maxHeight: .infinity, alignment: .top)

            remoteActionBar
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.transferQueue.map(\.status))
        .animation(.easeInOut(duration: 0.2), value: transferQueueOverlayState)
        .overlay {
            if transferQueueOverlayState.isExpanded, transferQueueOverlayState.isPinned == false {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        transferQueueOverlayState.handleOutsideClick()
                    }
                    .accessibilityIdentifier("file-manager-transfer-outside-dismiss")
            }
        }
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
            transferQueueOverlayState.handleTaskAvailabilityChanged(hasTasks: hasTransferTasks)
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
            if remoteSearchScope != .entireServer,
               !remoteSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                scheduleRemoteSearch()
            }
        }
        .onChange(of: remoteSearchDraft) {
            scheduleRemoteSearch()
        }
        .onChange(of: remoteSearchScope) {
            scheduleRemoteSearch(immediate: true)
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
            remoteSearchDebounceTask?.cancel()
            remoteSearchDebounceTask = nil
            viewModel.cancelRemoteSearch()
            toastHideTask?.cancel()
            toastHideTask = nil
            operationToast = nil
        }
    }

    private var remotePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            remoteToolbar
            if isShowingSearchResults {
                remoteSearchStatusStrip
            }
            remoteListHeader

            ScrollViewReader { proxy in
                List {
                    ForEach(Array(displayedRemoteItems.enumerated()), id: \.element.path) { rowIndex, item in
                        let isSelected = selectedRemotePaths.contains(item.path)
                        let isDropTarget = activeRemoteDropDirectoryPath == item.path
                        remoteListRow(item, isDropTarget: isDropTarget)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            Rectangle()
                                .fill(
                                    isSelected
                                        ? Color.accentColor
                                        : (
                                            activeRemoteDropDirectoryPath == item.path
                                                ? Color.accentColor.opacity(0.24)
                                                : rowBackgroundColor(rowIndex: rowIndex, isHovered: hoveredRemotePath == item.path)
                                        )
                                )
                        )
                        .scaleEffect(isDropTarget ? 1.012 : 1.0, anchor: .center)
                        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isDropTarget)
                        .contentShape(Rectangle())
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .tag(item.path)
                        .accessibilityIdentifier(remoteRowIdentifier(item.path))
                        .onTapGesture {
                            handleRemoteRowTap(item)
                        }
                        .onHover { hovering in
                            hoveredRemotePath = hovering ? item.path : nil
                        }
                        .dropDestination(for: URL.self) { items, _ in
                            handleRemoteDrop(items: items, targetEntry: makeRemoteFileEntry(from: item))
                        } isTargeted: { isTargeted in
                            updateRemoteDropTarget(for: makeRemoteFileEntry(from: item), isTargeted: isTargeted)
                        }
                        .contextMenu {
                            rowContextMenu(for: item)
                        }
                    }
                }
                .onChange(of: viewModel.remoteDirectoryPath) {
                    guard let firstPath = displayedRemoteItems.first?.path else {
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
                    } else if isShowingSearchResults,
                              !viewModel.remoteSearchStatus.isRunning,
                              displayedRemoteItems.isEmpty
                    {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text(String(format: tr("No files or folders match “%@”."), viewModel.remoteSearchStatus.query))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(VisualStyle.overlayBackground)
                        )
                        .padding(16)
                        .accessibilityIdentifier("file-manager-search-empty")
                    } else if !isShowingSearchResults,
                              displayedRemoteItems.isEmpty,
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
            sortHeaderButton(
                isShowingSearchResults ? tr("Path") : tr("Name"),
                column: .name,
                width: nil,
                alignment: .leading
            )
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
            guard !isShowingSearchResults else { return }
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
        .disabled(isShowingSearchResults)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width, alignment: alignment)
        .contentShape(Rectangle())
        .accessibilityIdentifier("file-manager-sort-\(column.rawValue)")
    }

    private func remoteListRow(_ item: RemoteListRowItem, isDropTarget: Bool = false) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .foregroundStyle(remoteSecondaryTextColor(for: item.path))
                Text(item.displayName)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(remotePrimaryTextColor(for: item.path))
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(permissionString(for: item))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(remoteSecondaryTextColor(for: item.path))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(remoteDateText(for: item.modifiedAt))
                .font(.system(size: 13))
                .foregroundStyle(remoteSecondaryTextColor(for: item.path))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            Text(remoteSizeText(for: item.size))
                .font(.system(size: 13))
                .foregroundStyle(remoteSecondaryTextColor(for: item.path))
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)

            Text(kindString(for: item))
                .font(.system(size: 13))
                .foregroundStyle(remoteSecondaryTextColor(for: item.path))
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

    private func remoteDateText(for date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = Self.remoteDateFormatter
        formatter.locale = AppLanguageMode.preferredLocale()
        return formatter.string(from: date)
    }

    private func permissionString(for item: RemoteListRowItem) -> String {
        guard let permission = item.permissions else {
            return "—"
        }
        return permissionString(mode: permission, isDirectory: item.isDirectory)
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

    private func remoteSizeText(for size: Int64?) -> String {
        guard let size else { return "—" }
        return ByteSizeFormatter.format(size)
    }

    private func kindString(for item: RemoteListRowItem) -> String {
        item.isDirectory ? tr("Folder") : tr("File")
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
        HStack(spacing: 6) {
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

            HStack(spacing: 4) {
                TextField("/path/to/dir", text: $remotePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.caption.monospaced())
                    .frame(minWidth: 180, maxWidth: .infinity)
                    .frame(height: 26)
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
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.68))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )

            toolbarToggleChip(
                title: tr("Terminal Sync"),
                systemImage: "link",
                accessibilityIdentifier: "file-manager-sync-toggle",
                isOn: viewModel.isTerminalDirectorySyncEnabled
            ) {
                viewModel.isTerminalDirectorySyncEnabled.toggle()
            }
        }
    }

    private var remoteActionBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    remoteSearchControls

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
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasTransferTasks, !transferQueueOverlayState.isExpanded {
                transferQueueCollapsedInlineControl
            }
        }
    }

    private var remoteSearchControls: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(RemoteSearchScope.allCases) { scope in
                    Button {
                        remoteSearchScope = scope
                    } label: {
                        if scope == remoteSearchScope {
                            Label(scope.title, systemImage: "checkmark")
                        } else {
                            Text(scope.title)
                        }
                    }
                }
            } label: {
                Label(remoteSearchScope.title, systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(tr("Search scope"))
            .accessibilityIdentifier("file-manager-search-scope")

            TextField(tr("Search files and folders"), text: $remoteSearchDraft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption)
                .frame(width: 180)
                .frame(height: 26)
                .focused($isRemoteSearchFieldFocused)
                .onSubmit {
                    scheduleRemoteSearch(immediate: true)
                }
                .accessibilityIdentifier("file-manager-search-field")

            if viewModel.remoteSearchStatus.isRunning {
                Button {
                    remoteSearchDebounceTask?.cancel()
                    remoteSearchDebounceTask = nil
                    viewModel.cancelRemoteSearch()
                }
                label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tr("Stop Search"))
                .accessibilityIdentifier("file-manager-search-stop")
            } else if !remoteSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    remoteSearchDraft = ""
                    viewModel.clearRemoteSearch()
                }
                label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tr("Clear Search"))
                .accessibilityIdentifier("file-manager-search-clear")
            }
        }
    }

    private var remoteSearchStatusStrip: some View {
        let searchStatus = viewModel.remoteSearchStatus

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(compactRemoteSearchSummary(searchStatus))
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if searchStatus.isResultTruncated {
                    Text(String(format: tr("Showing the first %d matches."), FileTransferViewModel.maxRemoteSearchResults))
                        .font(.caption)
                        .foregroundStyle(VisualStyle.textSecondary)
                        .lineLimit(1)
                }
            }

            if searchStatus.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityIdentifier("file-manager-search-progress")
            }

            if searchStatus.isRunning, !searchStatus.activity.isEmpty {
                RemoteSearchActivityTicker(activities: searchStatus.activity)
                    .accessibilityIdentifier("file-manager-search-activity")
            }

            if let errorMessage = searchStatus.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
    }

    private func compactRemoteSearchSummary(_ status: RemoteSearchStatus) -> String {
        if let statusText = status.statusText,
           !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "\(remoteSearchScopeDescription(status))  ·  \(statusText)"
        }
        return remoteSearchScopeDescription(status)
    }

    private var transferQueueFloatingOverlay: some View {
        Group {
            if hasTransferTasks, transferQueueOverlayState.isExpanded {
                transferQueueExpandedPanel
            }
        }
    }

    private var transferQueueCollapsedInlineControl: some View {
        Button {
            transferQueueOverlayState.expand()
        } label: {
            ProgressView(value: transferQueueSummary.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(width: 104)
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
                toolbarIconButton(
                    transferQueueOverlayState.isPinned ? "pin.fill" : "pin",
                    accessibilityIdentifier: "file-manager-transfer-pin",
                    helpText: transferQueueOverlayState.isPinned ? tr("Unpin Transfer Queue") : tr("Pin Transfer Queue"),
                    disabled: false
                ) {
                    transferQueueOverlayState.togglePinned()
                }
                toolbarIconButton(
                    "stop.circle",
                    accessibilityIdentifier: "file-manager-transfer-stop-all",
                    helpText: tr("Stop All Transfers"),
                    disabled: !hasStoppableTransfers
                ) {
                    viewModel.stopAllTransfers()
                }
                toolbarIconButton(
                    "chevron.down",
                    accessibilityIdentifier: "file-manager-transfer-collapse",
                    helpText: tr("Collapse Transfer Queue"),
                    disabled: false
                ) {
                    transferQueueOverlayState.collapse()
                }
            }

            HStack(spacing: 8) {
                Text("\(tr("Save To:")) \(abbreviatedLocalDirectoryPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)

                toolbarIconButton(
                    "square.and.pencil",
                    accessibilityIdentifier: "file-manager-open-download-settings",
                    helpText: tr("Edit download directory"),
                    disabled: false
                ) {
                    onEditDownloadPath?()
                }

                Spacer()

                toolbarTextButton(
                    tr("Open Folder"),
                    accessibilityIdentifier: "file-manager-open-download-folder",
                    disabled: false
                ) {
                    revealInFinder(path: viewModel.localDirectoryURL.path)
                }
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
                            if item.status == .queued || item.status == .running {
                                Button {
                                    viewModel.stopTransfer(itemID: item.id)
                                } label: {
                                    Image(systemName: "stop.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help(tr("Stop Transfer"))
                                .accessibilityIdentifier("file-manager-transfer-stop-\(item.id.uuidString)")
                            }
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
        contextMenuButton(tr("Refresh"), systemImage: ContextMenuIconCatalog.refresh) {
            viewModel.performContextAction(.refresh)
        }

        Divider()

        contextMenuButton(tr("New File"), systemImage: ContextMenuIconCatalog.newFile) {
            beginCreateRemote(kind: .file, in: viewModel.remoteDirectoryPath)
        }

        contextMenuButton(tr("New Folder"), systemImage: ContextMenuIconCatalog.newFolder) {
            beginCreateRemote(kind: .directory, in: viewModel.remoteDirectoryPath)
        }

        Divider()

        if viewModel.canPaste(into: viewModel.remoteDirectoryPath) {
            contextMenuButton(tr("Paste"), systemImage: ContextMenuIconCatalog.paste) {
                performRemoteContextAction(
                    .paste(destinationDirectory: viewModel.remoteDirectoryPath),
                    feedback: makePasteFeedback(destination: viewModel.remoteDirectoryPath)
                )
            }
        }

        contextMenuButton(tr("Upload To Current Directory"), systemImage: ContextMenuIconCatalog.upload) {
            presentUploadPanel(targetDirectory: viewModel.remoteDirectoryPath)
        }

        if !selectedRemotePaths.isEmpty {
            Divider()

            contextMenuButton(tr("Compress Selected"), systemImage: ContextMenuIconCatalog.compress) {
                beginCompress(paths: Array(selectedRemotePaths))
            }

            if selectedRemotePaths.count == 1,
               let selectedPath = selectedRemotePaths.first,
               let selectedEntry = viewModel.remoteEntries.first(where: { $0.path == selectedPath }),
               !selectedEntry.isDirectory,
               ArchiveFormat.extractFormat(for: selectedEntry.name) != nil
            {
                contextMenuButton(tr("Extract To"), systemImage: ContextMenuIconCatalog.extract) {
                    beginExtract(path: selectedEntry.path, destinationDirectory: viewModel.remoteDirectoryPath)
                }
            }
        }
    }

    @ViewBuilder
    private func rowContextMenu(for item: RemoteListRowItem) -> some View {
        contextMenuButton(tr("Refresh"), systemImage: ContextMenuIconCatalog.refresh) {
            viewModel.performContextAction(.refresh)
        }

        Divider()

        contextMenuButton(tr("Rename"), systemImage: ContextMenuIconCatalog.rename) {
            beginRename(path: item.path)
        }

        contextMenuButton(tr("Copy"), systemImage: ContextMenuIconCatalog.copy) {
            performRemoteContextAction(
                .copy(paths: [item.path]),
                feedback: makeCopyFeedback(count: 1)
            )
        }

        contextMenuButton(tr("Cut"), systemImage: "scissors") {
            performRemoteContextAction(
                .cut(paths: [item.path]),
                feedback: makeCutFeedback(count: 1)
            )
        }

        if viewModel.canPaste(into: item.isDirectory ? item.path : viewModel.remoteDirectoryPath) {
            contextMenuButton(tr("Paste"), systemImage: ContextMenuIconCatalog.paste) {
                let destination = item.isDirectory ? item.path : viewModel.remoteDirectoryPath
                performRemoteContextAction(
                    .paste(destinationDirectory: destination),
                    feedback: makePasteFeedback(destination: destination)
                )
            }
        }

        if item.isDirectory {
            contextMenuButton(tr("New File Here"), systemImage: ContextMenuIconCatalog.newFile) {
                beginCreateRemote(kind: .file, in: item.path)
            }

            contextMenuButton(tr("New Folder Here"), systemImage: ContextMenuIconCatalog.newFolder) {
                beginCreateRemote(kind: .directory, in: item.path)
            }
        }

        let selectedDownloadPaths = FileManagerContextMenuPolicy.downloadablePaths(for: selectedRemotePaths)
        let shouldSplitDownloadActions = selectedDownloadPaths.count > 1
            && selectedRemotePaths.contains(item.path)

        if shouldSplitDownloadActions {
            contextMenuButton(tr("Download Current"), systemImage: ContextMenuIconCatalog.download) {
                performRemoteContextAction(
                    .download(paths: [item.path]),
                    feedback: makeDownloadQueuedFeedback(count: 1)
                )
            }
            .disabled(FileManagerContextMenuPolicy.isDownloadDisabled(isDirectory: item.isDirectory))

            contextMenuButton("\(tr("Download Selected")) (\(selectedDownloadPaths.count))", systemImage: ContextMenuIconCatalog.download) {
                performRemoteContextAction(
                    .download(paths: selectedDownloadPaths),
                    feedback: makeDownloadQueuedFeedback(count: selectedDownloadPaths.count)
                )
            }
            .disabled(selectedDownloadPaths.isEmpty)
        } else {
            contextMenuButton(tr("Download"), systemImage: ContextMenuIconCatalog.download) {
                performRemoteContextAction(
                    .download(paths: [item.path]),
                    feedback: makeDownloadQueuedFeedback(count: 1)
                )
            }
            .disabled(FileManagerContextMenuPolicy.isDownloadDisabled(isDirectory: item.isDirectory))
        }

        contextMenuButton(tr("Move To"), systemImage: ContextMenuIconCatalog.moveTo) {
            moveSourcePaths = [item.path]
            moveTargetPath = viewModel.remoteDirectoryPath
            isMoveSheetPresented = true
        }

        contextMenuButton(tr("Compress"), systemImage: ContextMenuIconCatalog.compress) {
            beginCompress(paths: [item.path])
        }

        Divider()

        if !item.isDirectory {
            contextMenuButton(tr("Live View"), systemImage: ContextMenuIconCatalog.liveView) {
                beginViewLog(item)
            }

            contextMenuButton(tr("Edit"), systemImage: ContextMenuIconCatalog.edit) {
                beginEdit(item)
            }
        }

        contextMenuButton(tr("Copy Path"), systemImage: ContextMenuIconCatalog.copyPath) {
            copyToPasteboard(item.path)
        }

        contextMenuButton(tr("Copy Name"), systemImage: ContextMenuIconCatalog.copy) {
            copyToPasteboard(item.name)
        }

        contextMenuButton(tr("Properties"), systemImage: ContextMenuIconCatalog.properties) {
            propertiesTargetPath = item.path
        }

        if !item.isDirectory, ArchiveFormat.extractFormat(for: item.name) != nil {
            contextMenuButton(tr("Extract To"), systemImage: ContextMenuIconCatalog.extract) {
                beginExtract(path: item.path, destinationDirectory: viewModel.remoteDirectoryPath)
            }
        }

        contextMenuButton(tr("Edit Permissions"), systemImage: ContextMenuIconCatalog.permissions) {
            permissionsEditorTargetPath = item.path
        }

        if item.isDirectory {
            Divider()
            contextMenuButton(tr("Upload To Current Directory"), systemImage: ContextMenuIconCatalog.upload) {
                presentUploadPanel(targetDirectory: item.path)
            }
        }

        Divider()

        contextMenuButton(tr("Delete"), systemImage: ContextMenuIconCatalog.delete, role: .destructive) {
            performRemoteContextAction(
                .delete(paths: [item.path]),
                feedback: makeDeleteFeedback(count: 1)
            )
            selectedRemotePaths.remove(item.path)
            if selectionAnchorRemotePath == item.path {
                selectionAnchorRemotePath = nil
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
        case .queued, .stopped:
            return 0
        }
    }

    private func transferStatusText(for item: TransferItem) -> String {
        let localizedStatus = tr(item.status.rawValue)
        switch item.status {
        case .running:
            if let speed = item.speedBytesPerSecond, speed > 0 {
                return "\(localizedStatus) · \(ByteSizeFormatter.formatRate(speed))"
            }
            return localizedStatus
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
        case .stopped:
            return .secondary
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
            .frame(width: 28, height: 26)
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

    @ViewBuilder
    private func toolbarTextButton(
        _ title: String,
        accessibilityIdentifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(disabled ? VisualStyle.textTertiary : VisualStyle.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
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
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func toolbarToggleChip(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOn ? Color.accentColor : VisualStyle.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isOn
                            ? Color.accentColor.opacity(0.10)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isOn
                            ? Color.accentColor.opacity(0.35)
                            : Color(nsColor: .separatorColor).opacity(0.7),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? tr("Disable terminal sync") : tr("Enable terminal sync"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func handleRemoteRowTap(_ item: RemoteListRowItem) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let orderedPaths = displayedRemoteItems.map(\.path)
        let result = RemoteListSelection.applyClick(
            currentSelection: selectedRemotePaths,
            anchorPath: selectionAnchorRemotePath,
            orderedPaths: orderedPaths,
            clickedPath: item.path,
            modifiers: modifiers
        )
        selectedRemotePaths = result.selectedPaths
        selectionAnchorRemotePath = result.anchorPath

        let now = Date()
        if item.isDirectory,
           lastTappedRemotePath == item.path,
           now.timeIntervalSince(lastRemoteTapAt) < 0.32
        {
            viewModel.openRemote(makeRemoteFileEntry(from: item))
            selectedRemotePaths.removeAll()
            selectionAnchorRemotePath = nil
            lastTappedRemotePath = nil
            lastRemoteTapAt = .distantPast
            return
        }

        if !item.isDirectory,
           lastTappedRemotePath == item.path,
           now.timeIntervalSince(lastRemoteTapAt) < 0.32
        {
            showOperationToast(tr("To edit this file, right-click it and choose Edit."))
            lastTappedRemotePath = nil
            lastRemoteTapAt = .distantPast
            return
        }

        lastTappedRemotePath = item.path
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

    private func beginEdit(_ item: RemoteListRowItem) {
        guard !item.isDirectory else { return }
        let entry = makeRemoteFileEntry(from: item)
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

    private func beginViewLog(_ item: RemoteListRowItem) {
        guard !item.isDirectory else { return }
        logViewerTargetPath = item.path
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
            transferQueueOverlayState.expand()
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
            contextMenuButton(tr("Copy Local Path"), systemImage: ContextMenuIconCatalog.copyPath) {
                copyToPasteboard(item.destinationPath)
            }

            if FileManager.default.fileExists(atPath: item.destinationPath) {
                contextMenuButton(tr("Reveal in Finder"), systemImage: ContextMenuIconCatalog.reveal) {
                    revealInFinder(path: item.destinationPath)
                }
            }
        } else {
            contextMenuButton(tr("Copy Destination Path"), systemImage: ContextMenuIconCatalog.copyPath) {
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

    private func makeRemoteListRowItem(from entry: RemoteFileEntry) -> RemoteListRowItem {
        let parentPath = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
        return RemoteListRowItem(
            path: entry.path,
            displayName: entry.name,
            name: entry.name,
            parentPath: parentPath.isEmpty ? "/" : parentPath,
            size: entry.size,
            permissions: entry.permissions,
            modifiedAt: entry.modifiedAt,
            isDirectory: entry.isDirectory
        )
    }

    private func makeRemoteListRowItem(from result: RemoteSearchResult) -> RemoteListRowItem {
        return RemoteListRowItem(
            path: result.path,
            displayName: searchDisplayName(for: result),
            name: result.name,
            parentPath: result.parentPath,
            size: nil,
            permissions: nil,
            modifiedAt: nil,
            isDirectory: result.isDirectory
        )
    }

    private func makeRemoteFileEntry(from item: RemoteListRowItem) -> RemoteFileEntry {
        RemoteFileEntry(
            name: item.name,
            path: item.path,
            size: item.size ?? 0,
            permissions: item.permissions,
            isDirectory: item.isDirectory,
            modifiedAt: item.modifiedAt ?? .distantPast
        )
    }

    private func searchDisplayName(for result: RemoteSearchResult) -> String {
        let rootPath = viewModel.remoteSearchStatus.rootPath
        guard rootPath != "/" else {
            return result.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        let normalizedRoot = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        guard result.path.hasPrefix(normalizedRoot) else { return result.path }
        let relative = String(result.path.dropFirst(normalizedRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? result.name : relative
    }

    private func scheduleRemoteSearch(immediate: Bool = false) {
        remoteSearchDebounceTask?.cancel()
        remoteSearchDebounceTask = nil

        let trimmedQuery = remoteSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            viewModel.clearRemoteSearch()
            return
        }

        let delay: Duration = immediate || remoteSearchScope == .currentDirectory
            ? .zero
            : .milliseconds(260)
        let searchScope = remoteSearchScope
        let searchRootPath = remoteSearchRootPath

        remoteSearchDebounceTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            viewModel.performRemoteSearch(
                query: trimmedQuery,
                scope: searchScope,
                rootPath: searchRootPath
            )
        }
    }

    private func closeRemoteSearch() {
        remoteSearchDebounceTask?.cancel()
        remoteSearchDebounceTask = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            isRemoteSearchPresented = false
        }
        isRemoteSearchFieldFocused = false
    }

    private func remoteSearchScopeDescription(_ status: RemoteSearchStatus) -> String {
        switch status.scope {
        case .currentDirectory:
            return String(format: tr("Current directory: %@"), status.rootPath)
        case .currentDirectoryRecursive:
            return String(format: tr("Subfolders in %@"), status.rootPath)
        case .entireServer:
            return tr("Scope: entire server")
        }
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

private struct RemoteSearchActivityTicker: View {
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
