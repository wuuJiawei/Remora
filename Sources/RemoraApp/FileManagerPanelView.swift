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

    @ObservedObject var viewModel: FileTransferViewModel
    @RemoraStored(\.languageModeRawValue) private var languageModeRawValue: String
    var quickPaths: [HostQuickPath] = []
    var onRunQuickPath: (HostQuickPath) -> Void = { _ in }
    var onManageQuickPaths: () -> Void = {}
    var onAddCurrentQuickPath: (String) -> Void = { _ in }
    var onRefreshRemote: () -> Void = {}
    var onEditDownloadPath: (() -> Void)?
    @StateObject private var remoteEditorWindowManager: RemoteTextEditorWindowManager
    @StateObject private var remoteLiveLogWindowManager: RemoteLiveLogWindowManager

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
    @State private var isQuickPathRenameSheetPresented = false
    @State private var quickPathRenameTarget: HostQuickPath?
    @State private var quickPathRenameDraft = ""
    @State private var isRenameSheetPresented = false
    @State private var renameTargetPath: String?
    @State private var renameDraft = ""
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
    @State private var createRemoteKind: FileManagerRemoteCreateKind = .file
    @State private var createRemoteTargetDirectory = "/"
    @State private var createRemoteNameDraft = ""
    @State private var transferQueueOverlayState = TransferQueueOverlayState()
    @State var remoteSortColumn: FileManagerRemoteSortColumn = .name
    @State var isRemoteSortAscending = true
    @State private var activeRemoteDropDirectoryPath: String?
    @State private var isRemoteListDropTargeted = false
    @State private var operationToast: FileManagerOperationToast?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var isRemoteSearchPresented = true
    @State private var remoteSearchDraft = ""
    @State private var remoteSearchScope: RemoteSearchScope = .currentDirectory
    @State private var remoteSearchDebounceTask: Task<Void, Never>?
    @State var remoteListPresentation = FileManagerRemoteListPresentationCache.empty
    @State private var remoteTreeRoot = FileManagerRemoteTreeNode(
        path: "/",
        name: tr("Root"),
        depth: 0,
        isExpanded: true,
        isLoading: false,
        childrenLoaded: false,
        children: []
    )
    @State private var selectedRemoteSidebarItem: FileManagerRemoteSidebarItem = .directory("/")
    @FocusState private var isRemoteSearchFieldFocused: Bool

    init(
        viewModel: FileTransferViewModel,
        quickPaths: [HostQuickPath] = [],
        onRunQuickPath: @escaping (HostQuickPath) -> Void = { _ in },
        onManageQuickPaths: @escaping () -> Void = {},
        onAddCurrentQuickPath: @escaping (String) -> Void = { _ in },
        onRefreshRemote: @escaping () -> Void = {},
        onEditDownloadPath: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.quickPaths = quickPaths
        self.onRunQuickPath = onRunQuickPath
        self.onManageQuickPaths = onManageQuickPaths
        self.onAddCurrentQuickPath = onAddCurrentQuickPath
        self.onRefreshRemote = onRefreshRemote
        self.onEditDownloadPath = onEditDownloadPath
        _remoteEditorWindowManager = StateObject(
            wrappedValue: RemoteTextEditorWindowManager(fileTransfer: viewModel)
        )
        _remoteLiveLogWindowManager = StateObject(
            wrappedValue: RemoteLiveLogWindowManager(fileTransfer: viewModel)
        )
    }

    private var selectedRemoteEntries: [RemoteFileEntry] {
        selectedRemotePaths.compactMap { remoteListPresentation.itemsByPath[$0]?.sourceEntry }
    }

    var isShowingSearchResults: Bool {
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

    private var remoteDropHintText: String? {
        guard let target = activeRemoteDropTargetDirectoryPath else { return nil }
        return String(format: tr("Drop to upload to %@"), target)
    }

    private var displayedRemoteItems: [FileManagerRemoteListRowItem] {
        remoteListPresentation.items
    }

    private var displayedRemotePaths: [String] {
        remoteListPresentation.paths
    }

    private var visibleRemoteTreeNodes: [FileManagerRemoteTreeNode] {
        flattenVisibleRemoteTreeNodes(from: remoteTreeRoot)
    }

    private var currentBreadcrumbs: [String] {
        let components = pathComponents(for: viewModel.remoteDirectoryPath)
        return components.isEmpty ? [tr("Root")] : [tr("Root")] + components
    }

    private var rootContent: some View {
        VStack(spacing: 8) {
            HSplitView {
                remoteSidebar
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

                remotePanel
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: 150, maxHeight: .infinity, alignment: .top)

            remoteActionBar
        }
        .animation(.easeInOut(duration: 0.16), value: remoteTreeRoot)
        .animation(.easeInOut(duration: 0.2), value: selectedRemoteSidebarItem)
        .animation(.easeInOut(duration: 0.2), value: viewModel.remoteDirectoryPath)
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
    }

    private var lifecycleContent: AnyView {
        AnyView(
            rootContent
        .onChange(of: hasTransferTasks) {
            transferQueueOverlayState.handleTaskAvailabilityChanged(hasTasks: hasTransferTasks)
        }
        .onAppear {
            remotePathDraft = viewModel.remoteDirectoryPath
            selectedRemoteSidebarItem = .directory(viewModel.remoteDirectoryPath)
            rebuildDisplayedRemoteItems()
            Task {
                await loadInitialRemoteTreeIfNeeded()
                await syncRemoteTreeSelection(to: viewModel.remoteDirectoryPath)
            }
        }
        .onChange(of: viewModel.remoteDirectoryPath) {
            remotePathDraft = viewModel.remoteDirectoryPath
            selectedRemoteSidebarItem = .directory(viewModel.remoteDirectoryPath)
            selectedRemotePaths.removeAll()
            selectionAnchorRemotePath = nil
            activeRemoteDropDirectoryPath = nil
            isRemoteListDropTargeted = false
            Task {
                await syncRemoteTreeSelection(to: viewModel.remoteDirectoryPath)
            }
            if remoteSearchScope != .entireServer,
               !remoteSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                scheduleRemoteSearch()
            }
        }
        .onChange(of: viewModel.remoteEntries) {
            rebuildDisplayedRemoteItems()
            refreshVisibleTreeBranchFromVisibleEntries()
        }
        .onChange(of: viewModel.remoteSearchResults) {
            rebuildDisplayedRemoteItems()
        }
        .onChange(of: viewModel.remoteSearchStatus.query) {
            rebuildDisplayedRemoteItems()
        }
        .onChange(of: viewModel.remoteSearchStatus.rootPath) {
            rebuildDisplayedRemoteItems()
        }
        .onChange(of: remoteSortColumn) {
            rebuildDisplayedRemoteItems()
        }
        .onChange(of: isRemoteSortAscending) {
            rebuildDisplayedRemoteItems()
        }
        .onChange(of: languageModeRawValue) {
            rebuildDisplayedRemoteItems()
        }
        .onChange(of: remoteSearchDraft) {
            scheduleRemoteSearch()
        }
        .onChange(of: remoteSearchScope) {
            scheduleRemoteSearch(immediate: true)
        }
        )
    }

    private var remoteSidebar: some View {
        FileManagerRemoteSidebarView(
            remoteDirectoryPath: viewModel.remoteDirectoryPath,
            quickPaths: quickPaths,
            remoteTreeRoot: remoteTreeRoot,
            visibleRemoteTreeNodes: visibleRemoteTreeNodes,
            selectedItem: selectedRemoteSidebarItem,
            currentBreadcrumbs: currentBreadcrumbs,
            onSelectRoot: {
                selectedRemoteSidebarItem = .directory("/")
                navigateToRoot()
            },
            onSelectQuickPath: { quickPath in
                selectedRemoteSidebarItem = .quickPath(quickPath.id)
                onRunQuickPath(quickPath)
            },
            onSelectDirectory: { path in
                selectRemoteDirectory(path)
            },
            onToggleDirectory: { path in
                toggleRemoteTreeNode(path)
            },
            onManageQuickPaths: {
                onManageQuickPaths()
            },
            onAddCurrentQuickPath: {
                onAddCurrentQuickPath(viewModel.remoteDirectoryPath)
            },
            onRenameQuickPath: { quickPath in
                onManageQuickPaths()
                DispatchQueue.main.async {
                    beginRenameQuickPathFromSidebar(quickPath)
                }
            },
            onDeleteQuickPath: { quickPath in
                deleteQuickPathFromSidebar(quickPath)
            },
            onCopyDirectoryPath: { path in
                copyToPasteboard(path)
            },
            onRefreshDirectory: { path in
                refreshDirectoryNode(path)
            }
        )
    }

    private var sheetContent: AnyView {
        AnyView(
            lifecycleContent
        .sheet(isPresented: $isMoveSheetPresented) {
            moveSheet
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            renameSheet
        }
        .sheet(isPresented: $isQuickPathRenameSheetPresented) {
            quickPathRenameSheet
        }
        .sheet(isPresented: $isCreateRemoteSheetPresented) {
            createRemoteSheet
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
        )
    }

    var body: some View {
        sheetContent
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
                        FileManagerRemoteListRowView(
                            item: item,
                            rowIndex: rowIndex,
                            isSelected: isSelected,
                            isHovered: hoveredRemotePath == item.path,
                            isDropTarget: isDropTarget
                        )
                        .scaleEffect(isDropTarget ? 1.012 : 1.0, anchor: .center)
                        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isDropTarget)
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
                            handleRemoteDrop(items: items, targetEntry: remoteFileEntry(for: item))
                        } isTargeted: { isTargeted in
                            updateRemoteDropTarget(for: remoteFileEntry(for: item), isTargeted: isTargeted)
                        }
                        .contextMenu {
                            rowContextMenu(for: item)
                        }
                    }
                }
                .onChange(of: displayedRemotePaths) {
                    guard let firstPath = displayedRemotePaths.first else {
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

            HStack(spacing: 0) {
                TextField("/path/to/dir", text: $remotePathDraft)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .layoutPriority(1)
                    .onSubmit {
                        jumpToRemotePath()
                    }
                    .accessibilityIdentifier("file-manager-path-field")
                    .padding(.leading, 10)
                    .padding(.trailing, 8)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(width: 1, height: 18)
                    .padding(.trailing, 2)

                Button {
                    jumpToRemotePath()
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .frame(width: 30)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Go"))
                .accessibilityIdentifier("file-manager-go")
            }
            .frame(minWidth: 220, maxWidth: .infinity)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VisualStyle.inputFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.36), lineWidth: 1)
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
        .background(
            ViewScreenAnchorBridge(key: ViewScreenAnchorRegistry.transferQueueTarget)
        )
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
                .background(
                    ViewScreenAnchorBridge(key: ViewScreenAnchorRegistry.transferQueueTarget)
                )

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
    private func rowContextMenu(for item: FileManagerRemoteListRowItem) -> some View {
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

    private func handleRemoteRowTap(_ item: FileManagerRemoteListRowItem) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let result = RemoteListSelection.applyClick(
            currentSelection: selectedRemotePaths,
            anchorPath: selectionAnchorRemotePath,
            orderedPaths: displayedRemotePaths,
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
            viewModel.openRemote(remoteFileEntry(for: item))
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
            beginEdit(item)
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

    private func selectRemoteDirectory(_ path: String) {
        selectedRemoteSidebarItem = .directory(path)
        viewModel.navigateRemote(to: path)
    }

    private func beginRenameQuickPathFromSidebar(_ quickPath: HostQuickPath) {
        quickPathRenameTarget = quickPath
        quickPathRenameDraft = quickPath.name
        isQuickPathRenameSheetPresented = true
    }

    private func deleteQuickPathFromSidebar(_ quickPath: HostQuickPath) {
        // The host-level editor owns persisted quick-path mutations.
        // Sidebar delete currently routes users into that same management flow.
        onManageQuickPaths()
    }

    private func refreshDirectoryNode(_ path: String) {
        Task {
            await loadTreeChildren(for: path, forceRefresh: true)
            if normalizeTreePath(path) == normalizeTreePath(viewModel.remoteDirectoryPath) {
                onRefreshRemote()
            }
        }
    }

    private func commitQuickPathRenameFromSidebar() {
        guard quickPathRenameTarget != nil else { return }
        let trimmed = quickPathRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Persisted mutation still routes through the dedicated host editor flow for now.
        onManageQuickPaths()
        isQuickPathRenameSheetPresented = false
    }

    private func toggleRemoteTreeNode(_ path: String) {
        guard let node = nodeForPath(path, in: remoteTreeRoot) else { return }

        if node.isExpanded {
            remoteTreeRoot = updateNode(in: remoteTreeRoot, path: path) { node in
                node.isExpanded = false
            }
            return
        }

        remoteTreeRoot = updateNode(in: remoteTreeRoot, path: path) { node in
            node.isExpanded = true
            if !node.childrenLoaded {
                node.isLoading = true
            }
        }

        if !node.childrenLoaded {
            Task {
                await loadTreeChildren(for: path)
            }
        }
    }

    private func loadInitialRemoteTreeIfNeeded() async {
        if remoteTreeRoot.childrenLoaded {
            return
        }
        await loadTreeChildren(for: remoteTreeRoot.path)
    }

    private func refreshVisibleTreeBranchFromVisibleEntries() {
        guard let currentNode = nodeForPath(viewModel.remoteDirectoryPath, in: remoteTreeRoot),
              currentNode.childrenLoaded
        else {
            return
        }

        let directories = viewModel.remoteEntries
            .filter(\.isDirectory)
            .map { entry in
                FileManagerRemoteTreeNode(
                    path: entry.path,
                    name: entry.name,
                    depth: depthForTreePath(entry.path),
                    isExpanded: false,
                    isLoading: false,
                    childrenLoaded: false,
                    children: []
                )
            }

        remoteTreeRoot = updateNode(in: remoteTreeRoot, path: currentNode.path) { node in
            let existingByPath = Dictionary(uniqueKeysWithValues: node.children.map { ($0.path, $0) })
            node.children = directories.map { candidate in
                if let existing = existingByPath[candidate.path] {
                    var preserved = existing
                    preserved.name = candidate.name
                    preserved.depth = candidate.depth
                    return preserved
                }
                return candidate
            }
            node.childrenLoaded = true
            node.isLoading = false
        }
    }

    private func syncRemoteTreeSelection(to path: String) async {
        let normalized = normalizeTreePath(path)
        let components = pathComponents(for: normalized)
        if components.isEmpty {
            selectedRemoteSidebarItem = .directory("/")
            return
        }

        var currentPath = "/"
        for component in components {
            if currentPath != "/" {
                currentPath += "/"
            }
            currentPath += component

            if nodeForPath(currentPath, in: remoteTreeRoot) == nil {
                await loadTreeChildren(for: parentPath(of: currentPath) ?? "/", forceRefresh: false)
            }

            remoteTreeRoot = updateNode(in: remoteTreeRoot, path: parentPath(of: currentPath) ?? "/") { node in
                node.isExpanded = true
            }
        }
    }

    private func loadTreeChildren(for path: String, forceRefresh: Bool = false) async {
        let normalized = normalizeTreePath(path)

        await MainActor.run {
            remoteTreeRoot = updateNode(in: remoteTreeRoot, path: normalized) { node in
                node.isExpanded = true
                node.isLoading = true
            }
        }

        do {
            let entries = try await viewModel.listRemoteDirectory(path: normalized, preferCachedFirst: !forceRefresh)
            let directories = entries
                .filter(\.isDirectory)
                .map { entry in
                    FileManagerRemoteTreeNode(
                        path: entry.path,
                        name: entry.name,
                        depth: depthForTreePath(entry.path),
                        isExpanded: false,
                        isLoading: false,
                        childrenLoaded: false,
                        children: []
                    )
                }

            await MainActor.run {
                remoteTreeRoot = updateNode(in: remoteTreeRoot, path: normalized) { node in
                    let existingByPath = Dictionary(uniqueKeysWithValues: node.children.map { ($0.path, $0) })
                    node.children = directories.map { candidate in
                        if let existing = existingByPath[candidate.path] {
                            var preserved = existing
                            preserved.name = candidate.name
                            preserved.depth = candidate.depth
                            return preserved
                        }
                        return candidate
                    }
                    node.childrenLoaded = true
                    node.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                remoteTreeRoot = updateNode(in: remoteTreeRoot, path: normalized) { node in
                    node.isLoading = false
                    node.childrenLoaded = true
                    node.children = []
                }
            }
        }
    }

    private func nodeForPath(_ path: String, in node: FileManagerRemoteTreeNode) -> FileManagerRemoteTreeNode? {
        let normalized = normalizeTreePath(path)
        if node.path == normalized {
            return node
        }

        for child in node.children {
            if let found = nodeForPath(normalized, in: child) {
                return found
            }
        }
        return nil
    }

    private func updateNode(
        in node: FileManagerRemoteTreeNode,
        path: String,
        transform: (inout FileManagerRemoteTreeNode) -> Void
    ) -> FileManagerRemoteTreeNode {
        let normalized = normalizeTreePath(path)
        var updated = node

        if updated.path == normalized {
            transform(&updated)
            return updated
        }

        updated.children = updated.children.map { child in
            updateNode(in: child, path: normalized, transform: transform)
        }
        return updated
    }

    private func flattenVisibleRemoteTreeNodes(from node: FileManagerRemoteTreeNode) -> [FileManagerRemoteTreeNode] {
        var result: [FileManagerRemoteTreeNode] = [node]
        if node.isExpanded {
            for child in node.children {
                result.append(contentsOf: flattenVisibleRemoteTreeNodes(from: child))
            }
        }
        return result
    }

    private func normalizeTreePath(_ path: String) -> String {
        let normalized = NSString(string: path).standardizingPath
        if normalized.isEmpty {
            return "/"
        }
        return normalized.hasPrefix("/") ? normalized : "/\(normalized)"
    }

    private func pathComponents(for path: String) -> [String] {
        normalizeTreePath(path)
            .split(separator: "/")
            .map(String.init)
    }

    private func depthForTreePath(_ path: String) -> Int {
        max(pathComponents(for: path).count - 1, 0)
    }

    private func parentPath(of path: String) -> String? {
        Self.parentDirectoryPath(for: normalizeTreePath(path))
    }

    private func beginRename(path: String) {
        renameTargetPath = path
        renameDraft = URL(fileURLWithPath: path).lastPathComponent
        isRenameSheetPresented = true
    }

    private func beginEdit(_ item: FileManagerRemoteListRowItem) {
        guard !item.isDirectory else { return }
        let entry = remoteFileEntry(for: item)
        remoteEditorWindowManager.present(
            path: entry.path,
            loadOptions: RemoteTextDocumentLoadOptions(
                knownSize: entry.size,
                knownModifiedAt: entry.modifiedAt
            )
        )
    }

    private func beginViewLog(_ item: FileManagerRemoteListRowItem) {
        guard !item.isDirectory else { return }
        remoteLiveLogWindowManager.present(path: item.path)
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

    private func beginCreateRemote(kind: FileManagerRemoteCreateKind, in directoryPath: String) {
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

    private var quickPathRenameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Rename"))
                .font(.headline)

            TextField(tr("Name"), text: $quickPathRenameDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) {
                    isQuickPathRenameSheetPresented = false
                    quickPathRenameTarget = nil
                    quickPathRenameDraft = ""
                }
                Button(tr("Save")) {
                    commitQuickPathRenameFromSidebar()
                }
                .buttonStyle(.borderedProminent)
                .disabled(quickPathRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
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

    private func remoteRowIdentifier(_ path: String) -> String {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        return "file-manager-remote-row\(sanitized)"
    }

    private func rebuildDisplayedRemoteItems() {
        let items: [FileManagerRemoteListRowItem]

        if isShowingSearchResults {
            items = viewModel.remoteSearchResults.map(makeRemoteListRowItem(from:))
        } else {
            let locale = AppLanguageMode.preferredLocale(from: languageModeRawValue)
            let sortedEntries = viewModel.remoteEntries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }

                let order: ComparisonResult = switch remoteSortColumn {
                case .name:
                    compareLocalized(lhs.name, rhs.name, locale: locale, caseInsensitive: true)
                case .permission:
                    compareLocalized(permissionString(for: lhs), permissionString(for: rhs), locale: locale)
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
                    compareLocalized(kindString(for: lhs), kindString(for: rhs), locale: locale, caseInsensitive: true)
                }

                if order == .orderedSame {
                    return compareLocalized(lhs.name, rhs.name, locale: locale, caseInsensitive: true) == .orderedAscending
                }
                if isRemoteSortAscending {
                    return order == .orderedAscending
                }
                return order == .orderedDescending
            }
            items = sortedEntries.map(makeRemoteListRowItem(from:))
        }

        let paths = items.map(\.path)
        let itemsByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        remoteListPresentation = FileManagerRemoteListPresentationCache(
            items: items,
            paths: paths,
            itemsByPath: itemsByPath
        )

        let validPaths = Set(paths)
        selectedRemotePaths = selectedRemotePaths.intersection(validPaths)
        if let selectionAnchorRemotePath, !validPaths.contains(selectionAnchorRemotePath) {
            self.selectionAnchorRemotePath = nil
        }
        if let hoveredRemotePath, !validPaths.contains(hoveredRemotePath) {
            self.hoveredRemotePath = nil
        }
        if let lastTappedRemotePath, !validPaths.contains(lastTappedRemotePath) {
            self.lastTappedRemotePath = nil
            lastRemoteTapAt = .distantPast
        }
    }

    private func compareLocalized(
        _ lhs: String,
        _ rhs: String,
        locale: Locale,
        caseInsensitive: Bool = false
    ) -> ComparisonResult {
        var options: String.CompareOptions = [.diacriticInsensitive]
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        return lhs.compare(rhs, options: options, range: nil, locale: locale)
    }

    private func makeRemoteListRowItem(from entry: RemoteFileEntry) -> FileManagerRemoteListRowItem {
        let parentPath = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
        return FileManagerRemoteListRowItem(
            path: entry.path,
            displayName: entry.name,
            name: entry.name,
            parentPath: parentPath.isEmpty ? "/" : parentPath,
            size: entry.size,
            permissions: entry.permissions,
            modifiedAt: entry.modifiedAt,
            isDirectory: entry.isDirectory,
            permissionText: permissionString(for: entry),
            modifiedAtText: remoteDateText(for: entry.modifiedAt),
            sizeText: remoteSizeText(for: entry.size),
            kindText: kindString(for: entry),
            sourceEntry: entry
        )
    }

    private func makeRemoteListRowItem(from result: RemoteSearchResult) -> FileManagerRemoteListRowItem {
        return FileManagerRemoteListRowItem(
            path: result.path,
            displayName: searchDisplayName(for: result),
            name: result.name,
            parentPath: result.parentPath,
            size: nil,
            permissions: nil,
            modifiedAt: nil,
            isDirectory: result.isDirectory,
            permissionText: "—",
            modifiedAtText: "—",
            sizeText: "—",
            kindText: result.isDirectory ? tr("Folder") : tr("File"),
            sourceEntry: nil
        )
    }

    private func remoteFileEntry(for item: FileManagerRemoteListRowItem) -> RemoteFileEntry {
        item.sourceEntry ?? RemoteFileEntry(
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

    func remoteSearchScopeDescription(_ status: RemoteSearchStatus) -> String {
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
            operationToast = FileManagerOperationToast(message: trimmed)
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
    private func operationToastView(_ toast: FileManagerOperationToast) -> some View {
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
