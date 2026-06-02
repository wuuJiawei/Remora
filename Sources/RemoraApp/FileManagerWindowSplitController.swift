import AppKit
import RemoraCore

// Primary native file manager browser implementation. New window-based file
// manager work should be routed here instead of FileManagerPanelView.
@MainActor
final class FileManagerWindowSplitController: NSSplitViewController {
    private let sidebarController: FileManagerOutlineSidebarController
    private let detailController: FileManagerFinderDetailController

    init(
        selectedPath: String,
        quickPathsProvider: @escaping () -> [HostQuickPath],
        directoryChildrenProvider: @escaping (String) async throws -> [RemoteFileEntry],
        onSelectRoot: @escaping () -> Void,
        onSelectQuickPath: @escaping (HostQuickPath) -> Void,
        onSelectDirectory: @escaping (String) -> Void,
        onAddQuickPathForDirectory: @escaping (String) -> Void,
        onRenameQuickPath: @escaping (HostQuickPath) -> Void,
        onDeleteQuickPath: @escaping (HostQuickPath) -> Void,
        onReorderQuickPaths: @escaping ([UUID]) -> Void,
        onRefreshDirectory: @escaping (String) -> Void,
        onOpenDirectory: @escaping (RemoteFileEntry) -> Void,
        onRefreshCurrentDirectory: @escaping () -> Void,
        onAddCurrentQuickPath: @escaping (String) -> Void,
        onCreateDirectory: @escaping (String) -> Void,
        onCreateFile: @escaping (String) -> Void,
        onRenameEntry: @escaping (RemoteFileEntry) -> Void,
        onDeleteEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyPath: @escaping (String) -> Void,
        onUploadToDirectory: @escaping (String) -> Void
    ) {
        self.sidebarController = FileManagerOutlineSidebarController(
            selectedPath: selectedPath,
            quickPathsProvider: quickPathsProvider,
            directoryChildrenProvider: directoryChildrenProvider,
            onSelectRoot: onSelectRoot,
            onSelectQuickPath: onSelectQuickPath,
            onSelectDirectory: onSelectDirectory,
            onAddQuickPathForDirectory: onAddQuickPathForDirectory,
            onRenameQuickPath: onRenameQuickPath,
            onDeleteQuickPath: onDeleteQuickPath,
            onReorderQuickPaths: onReorderQuickPaths,
            onRefreshDirectory: onRefreshDirectory
        )
        self.detailController = FileManagerFinderDetailController(
            onOpenDirectory: onOpenDirectory,
            onRefresh: onRefreshCurrentDirectory,
            onAddCurrentQuickPath: onAddCurrentQuickPath,
            onCreateDirectory: onCreateDirectory,
            onCreateFile: onCreateFile,
            onRenameEntry: onRenameEntry,
            onDeleteEntries: onDeleteEntries,
            onCopyPath: onCopyPath,
            onUploadToDirectory: onUploadToDirectory
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 220
        sidebarItem.canCollapse = true

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 520

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    func reloadSidebar(selectedPath: String) {
        print("[FileManager][Sidebar] reloadSidebar selectedPath=\(selectedPath)")
        sidebarController.selectedPath = selectedPath
        sidebarController.reload()
    }

    func updateSidebarDirectorySnapshot(path: String, entries: [RemoteFileEntry]) {
        sidebarController.updateDirectorySnapshot(path: path, entries: entries)
    }

    func reloadDetail(
        currentPath: String,
        entries: [RemoteFileEntry],
        isLoading: Bool,
        searchQuery: String
    ) {
        print("[FileManager][Detail] reloadDetail path=\(currentPath) entries=\(entries.count) loading=\(isLoading) search=\(searchQuery)")
        detailController.update(
            currentPath: currentPath,
            entries: entries,
            isLoading: isLoading,
            searchQuery: searchQuery
        )
    }

    var currentSearchQuery: String {
        detailController.searchQuery
    }

    func updateSearchQuery(_ query: String) {
        detailController.searchQuery = query
    }

    func setPropertyHandlers(
        onShowProperties: @escaping (RemoteFileEntry) -> Void,
        onEditPermissions: @escaping (RemoteFileEntry) -> Void
    ) {
        detailController.onShowProperties = onShowProperties
        detailController.onEditPermissions = onEditPermissions
    }

    func setOpenHandlers(
        onOpenTextFile: @escaping (RemoteFileEntry) -> Void,
        onOpenLogView: @escaping (RemoteFileEntry) -> Void
    ) {
        detailController.onOpenTextFile = onOpenTextFile
        detailController.onOpenLogView = onOpenLogView
    }

    func setArchiveHandlers(
        onCompressEntries: @escaping ([RemoteFileEntry]) -> Void,
        onExtractEntry: @escaping (RemoteFileEntry) -> Void
    ) {
        detailController.onCompressEntries = onCompressEntries
        detailController.onExtractEntry = onExtractEntry
    }
}

@MainActor
private final class FileManagerOutlineSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var selectedPath: String

    private let quickPathsProvider: () -> [HostQuickPath]
    private let directoryChildrenProvider: (String) async throws -> [RemoteFileEntry]
    private let onSelectRoot: () -> Void
    private let onSelectQuickPath: (HostQuickPath) -> Void
    private let onSelectDirectory: (String) -> Void
    private let onAddQuickPathForDirectory: (String) -> Void
    private let onRenameQuickPath: (HostQuickPath) -> Void
    private let onDeleteQuickPath: (HostQuickPath) -> Void
    private let onReorderQuickPaths: ([UUID]) -> Void
    private let onRefreshDirectory: (String) -> Void

    private let outlineView = NSOutlineView()
    private var scrollView: NSScrollView!
    private var quickPathDropTargetID: UUID?
    private var isSelectingProgrammatically = false
    private let rootDirectoryNode = DirectoryNode(path: "/")
    private var directoryNodeCache: [String: DirectoryNode] = [:]
    private var directoryLoadTasks: [String: Task<Result<[RemoteFileEntry], Error>, Never>] = [:]
    private var selectionSyncTask: Task<Void, Never>?
    private var expandedDirectoryPaths: Set<String> = []

    private enum Section: Int, CaseIterable {
        case quickPaths
        case folders
    }

    private enum SidebarItemID {
        static let root = "__root__"
    }

    private enum ChildrenState {
        case unloaded
        case loading
        case loaded
    }

    private final class DirectoryNode: NSObject {
        let path: String
        var displayName: String
        var children: [DirectoryNode] = []
        var childrenState: ChildrenState = .unloaded

        init(path: String, displayName: String? = nil) {
            self.path = FileManagerOutlineSidebarController.normalizePath(path)
            self.displayName = displayName ?? FileManagerOutlineSidebarController.defaultDisplayName(for: path)
        }
    }

    init(
        selectedPath: String,
        quickPathsProvider: @escaping () -> [HostQuickPath],
        directoryChildrenProvider: @escaping (String) async throws -> [RemoteFileEntry],
        onSelectRoot: @escaping () -> Void,
        onSelectQuickPath: @escaping (HostQuickPath) -> Void,
        onSelectDirectory: @escaping (String) -> Void,
        onAddQuickPathForDirectory: @escaping (String) -> Void,
        onRenameQuickPath: @escaping (HostQuickPath) -> Void,
        onDeleteQuickPath: @escaping (HostQuickPath) -> Void,
        onReorderQuickPaths: @escaping ([UUID]) -> Void,
        onRefreshDirectory: @escaping (String) -> Void
    ) {
        self.selectedPath = selectedPath
        self.quickPathsProvider = quickPathsProvider
        self.directoryChildrenProvider = directoryChildrenProvider
        self.onSelectRoot = onSelectRoot
        self.onSelectQuickPath = onSelectQuickPath
        self.onSelectDirectory = onSelectDirectory
        self.onAddQuickPathForDirectory = onAddQuickPathForDirectory
        self.onRenameQuickPath = onRenameQuickPath
        self.onDeleteQuickPath = onDeleteQuickPath
        self.onReorderQuickPaths = onReorderQuickPaths
        self.onRefreshDirectory = onRefreshDirectory
        self.directoryNodeCache[rootDirectoryNode.path] = rootDirectoryNode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        self.view = NSView()
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        print("[FileManager][Sidebar] viewDidLoad")
        reload()
    }

    func reload() {
        selectedPath = Self.normalizePath(selectedPath)
        print("[FileManager][Sidebar] reload selectedPath=\(selectedPath) quickPaths=\(quickPathsProvider().count)")
        selectionSyncTask?.cancel()
        outlineView.reloadData()
        outlineView.expandItem(Section.quickPaths.rawValue)
        outlineView.expandItem(Section.folders.rawValue)
        restoreExpandedNodes()
        ensureRootChildrenLoadedIfNeeded()
        syncSelectionToSelectedPath()
    }

    func updateDirectorySnapshot(path: String, entries: [RemoteFileEntry]) {
        applyDirectorySnapshot(path: Self.normalizePath(path), entries: entries)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return Section.allCases.count }
        if let raw = item as? Int, let section = Section(rawValue: raw) {
            switch section {
            case .quickPaths:
                return 1 + quickPathsProvider().count
            case .folders:
                return rootDirectoryNode.children.count
            }
        }
        if let directory = item as? DirectoryNode {
            return directory.children.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if (item as? Int).flatMap(Section.init(rawValue:)) != nil {
            return true
        }
        guard let directory = item as? DirectoryNode else { return false }
        return directory.childrenState != .loaded || !directory.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return Section.allCases[index].rawValue }
        if let raw = item as? Int, let section = Section(rawValue: raw) {
            switch section {
            case .quickPaths:
                return index == 0 ? SidebarItemID.root : quickPathsProvider()[index - 1]
            case .folders:
                return rootDirectoryNode.children[index]
            }
        }
        if let directory = item as? DirectoryNode {
            return directory.children[index]
        }
        return SidebarItemID.root
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Int).flatMap(Section.init(rawValue:)) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Int).flatMap(Section.init(rawValue:)) == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("finder-sidebar-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let result = NSTableCellView()
            result.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            result.textField = textField
            result.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            ])
            return result
        }()

        if let raw = item as? Int, let section = Section(rawValue: raw) {
            cell.textField?.stringValue = section == .quickPaths ? tr("Quick Paths") : tr("Folders")
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }

        if item as? String == SidebarItemID.root {
            cell.textField?.stringValue = tr("Root")
            cell.textField?.font = .systemFont(ofSize: 13, weight: .regular)
            cell.textField?.textColor = selectedPath == "/" ? .controlAccentColor : .labelColor
            return cell
        }

        if let quickPath = item as? HostQuickPath {
            cell.textField?.stringValue = quickPath.name
            cell.textField?.font = .systemFont(ofSize: 13, weight: .regular)
            cell.textField?.textColor = selectedPath == quickPath.path ? .controlAccentColor : .labelColor
            return cell
        }

        if let directory = item as? DirectoryNode {
            cell.textField?.stringValue = directory.displayName
            cell.textField?.font = .systemFont(ofSize: 13, weight: .regular)
            cell.textField?.textColor = selectedPath == directory.path ? .controlAccentColor : .labelColor
            return cell
        }

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isSelectingProgrammatically {
            print("[FileManager][Sidebar] selectionDidChange ignored (programmatic)")
            return
        }
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        print("[FileManager][Sidebar] selectionDidChange row=\(row) item=\(String(describing: item))")
        if item as? String == SidebarItemID.root {
            if selectedPath == "/" {
                print("[FileManager][Sidebar] selectionDidChange skip root reselect")
                return
            }
            onSelectRoot()
        } else if let quickPath = item as? HostQuickPath {
            if quickPath.path == selectedPath {
                print("[FileManager][Sidebar] selectionDidChange skip quickPath reselect path=\(quickPath.path)")
                return
            }
            onSelectQuickPath(quickPath)
        } else if let directory = item as? DirectoryNode {
            if directory.path == selectedPath {
                print("[FileManager][Sidebar] selectionDidChange skip directory reselect path=\(directory.path)")
                return
            }
            onSelectDirectory(directory.path)
        }
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let directory = notification.userInfo?["NSObject"] as? DirectoryNode else { return }
        expandedDirectoryPaths.insert(directory.path)
        let path = directory.path
        Task { [weak self] in
            _ = await self?.loadChildrenIfNeeded(forPath: path)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let directory = notification.userInfo?["NSObject"] as? DirectoryNode else { return }
        expandedDirectoryPaths.remove(directory.path)
    }

    @objc private func handleDoubleClick() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        print("[FileManager][Sidebar] doubleClick row=\(row) item=\(String(describing: item))")
        if item as? String == SidebarItemID.root {
            onSelectRoot()
        } else if let directory = item as? DirectoryNode {
            onSelectDirectory(directory.path)
        }
    }

    private func ensureRootChildrenLoadedIfNeeded() {
        let rootPath = rootDirectoryNode.path
        Task { [weak self] in
            guard let self else { return }
            _ = await self.loadChildrenIfNeeded(forPath: rootPath)
        }
    }

    private func syncSelectionToSelectedPath() {
        if selectVisibleQuickPathOrRoot() {
            return
        }

        let targetPath = selectedPath
        selectionSyncTask = Task { [weak self] in
            guard let self else { return }
            await self.expandAndSelectDirectory(path: targetPath)
        }
    }

    private func selectVisibleQuickPathOrRoot() -> Bool {
        let rowCount = outlineView.numberOfRows
        isSelectingProgrammatically = true
        defer { isSelectingProgrammatically = false }
        for row in 0..<rowCount {
            let item = outlineView.item(atRow: row)
            if item as? String == SidebarItemID.root, selectedPath == "/" {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return true
            }
            if let quickPath = item as? HostQuickPath, quickPath.path == selectedPath {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return true
            }
        }
        return false
    }

    private func expandAndSelectDirectory(path: String) async {
        let normalizedPath = Self.normalizePath(path)
        guard normalizedPath != "/", !Task.isCancelled else { return }

        let components = ancestorPaths(for: normalizedPath)
        guard !components.isEmpty else { return }

        var parent = rootDirectoryNode
        for (index, componentPath) in components.enumerated() {
            let children = await loadChildrenIfNeeded(forPath: parent.path)
            guard !Task.isCancelled else { return }
            guard let nextNode = children.first(where: { $0.path == componentPath }) else { return }

            if index < components.count - 1 {
                outlineView.expandItem(nextNode)
            }
            parent = nextNode
        }

        guard !Task.isCancelled else { return }
        selectDirectoryNode(parent)
    }

    private func selectDirectoryNode(_ node: DirectoryNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        isSelectingProgrammatically = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isSelectingProgrammatically = false
    }

    private func loadChildrenIfNeeded(forPath path: String) async -> [DirectoryNode] {
        let node = directoryNode(forPath: path)
        if node.childrenState == .loaded {
            return node.children
        }

        let normalizedPath = node.path
        let task: Task<Result<[RemoteFileEntry], Error>, Never>
        if let existingTask = directoryLoadTasks[normalizedPath] {
            task = existingTask
        } else {
            node.childrenState = .loading
            let provider = directoryChildrenProvider
            task = Task {
                do {
                    let entries = try await provider(normalizedPath).filter(\.isDirectory)
                    return .success(entries)
                } catch {
                    return .failure(error)
                }
            }
            directoryLoadTasks[normalizedPath] = task
        }

        let result = await task.value
        guard !Task.isCancelled else { return node.children }
        if directoryLoadTasks[normalizedPath] != nil {
            directoryLoadTasks[normalizedPath] = nil
        }

        guard case let .success(entries) = result else {
            node.childrenState = .unloaded
            return node.children
        }
        applyDirectorySnapshot(path: normalizedPath, entries: entries)
        return node.children
    }

    private func applyDirectorySnapshot(path: String, entries: [RemoteFileEntry]) {
        let normalizedPath = Self.normalizePath(path)
        let node = directoryNode(forPath: normalizedPath)
        let childDirectories = entries.filter(\.isDirectory)
        node.children = childDirectories.map { entry in
            let childPath = Self.normalizePath(entry.path)
            let childNode = directoryNode(forPath: childPath, displayName: entry.name)
            childNode.displayName = entry.name
            return childNode
        }
        node.childrenState = .loaded

        if normalizedPath == rootDirectoryNode.path {
            outlineView.reloadItem(Section.folders.rawValue, reloadChildren: true)
        } else {
            outlineView.reloadItem(node, reloadChildren: true)
        }
        restoreExpandedNodes()
    }

    private func directoryNode(forPath path: String, displayName: String? = nil) -> DirectoryNode {
        let normalizedPath = Self.normalizePath(path)
        if let existing = directoryNodeCache[normalizedPath] {
            if let displayName, !displayName.isEmpty {
                existing.displayName = displayName
            }
            return existing
        }

        let node = DirectoryNode(path: normalizedPath, displayName: displayName)
        directoryNodeCache[normalizedPath] = node
        return node
    }

    private func restoreExpandedNodes() {
        let pathsToExpand = expandedDirectoryPaths
            .filter { $0 != "/" }
            .sorted { lhs, rhs in
                lhs.split(separator: "/").count < rhs.split(separator: "/").count
            }

        for path in pathsToExpand {
            guard let node = directoryNodeCache[path] else { continue }
            outlineView.expandItem(node)
        }
    }

    private func ancestorPaths(for path: String) -> [String] {
        let normalizedPath = Self.normalizePath(path)
        guard normalizedPath != "/" else { return [] }
        let components = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var running = ""
        return components.map { component in
            running += "/\(component)"
            return running
        }
    }

    nonisolated private static func normalizePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        guard trimmed != "/" else { return "/" }
        let leadingSlash = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        let collapsed = leadingSlash.replacingOccurrences(of: "//", with: "/")
        return collapsed.hasSuffix("/") && collapsed.count > 1
            ? String(collapsed.dropLast())
            : collapsed
    }

    nonisolated private static func defaultDisplayName(for path: String) -> String {
        let normalizedPath = normalizePath(path)
        guard normalizedPath != "/" else { return "Root" }
        return URL(fileURLWithPath: normalizedPath).lastPathComponent
    }
}

@MainActor
private final class FileManagerFinderDetailController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let onOpenDirectory: (RemoteFileEntry) -> Void
    private let onRefresh: () -> Void
    private let onAddCurrentQuickPath: (String) -> Void
    private let onCreateDirectory: (String) -> Void
    private let onCreateFile: (String) -> Void
    private let onRenameEntry: (RemoteFileEntry) -> Void
    private let onDeleteEntries: ([RemoteFileEntry]) -> Void
    private let onCopyPath: (String) -> Void
    private let onUploadToDirectory: (String) -> Void
    var onEditPermissions: ((RemoteFileEntry) -> Void)?
    var onShowProperties: ((RemoteFileEntry) -> Void)?
    var onOpenTextFile: ((RemoteFileEntry) -> Void)?
    var onOpenLogView: ((RemoteFileEntry) -> Void)?
    var onCompressEntries: (([RemoteFileEntry]) -> Void)?
    var onExtractEntry: ((RemoteFileEntry) -> Void)?

    private let tableView = NSTableView()
    private var scrollView: NSScrollView!
    private let emptyLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()

    private var currentPath = "/"
    private var entries: [RemoteFileEntry] = []
    private var isLoading = false
    private var sortColumn: Column = .name
    private var sortAscending = true
    private let defaults = UserDefaults.standard
    var searchQuery = "" {
        didSet { tableView.reloadData(); updateEmptyState() }
    }

    private enum Column: String, CaseIterable {
        case name
        case permission
        case date
        case size
        case kind

        var title: String {
            switch self {
            case .name: return tr("Name")
            case .permission: return tr("Permission")
            case .date: return tr("Date")
            case .size: return tr("Size")
            case .kind: return tr("Kind")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 280
            case .permission: return 120
            case .date: return 170
            case .size: return 90
            case .kind: return 90
            }
        }
    }

    init(
        onOpenDirectory: @escaping (RemoteFileEntry) -> Void,
        onRefresh: @escaping () -> Void,
        onAddCurrentQuickPath: @escaping (String) -> Void,
        onCreateDirectory: @escaping (String) -> Void,
        onCreateFile: @escaping (String) -> Void,
        onRenameEntry: @escaping (RemoteFileEntry) -> Void,
        onDeleteEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyPath: @escaping (String) -> Void,
        onUploadToDirectory: @escaping (String) -> Void
    ) {
        self.onOpenDirectory = onOpenDirectory
        self.onRefresh = onRefresh
        self.onAddCurrentQuickPath = onAddCurrentQuickPath
        self.onCreateDirectory = onCreateDirectory
        self.onCreateFile = onCreateFile
        self.onRenameEntry = onRenameEntry
        self.onDeleteEntries = onDeleteEntries
        self.onCopyPath = onCopyPath
        self.onUploadToDirectory = onUploadToDirectory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        print("[FileManager][Detail] loadView")

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = storedWidth(for: column) ?? column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.menu = buildContextMenu()

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false

        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            loadingIndicator.bottomAnchor.constraint(equalTo: emptyLabel.topAnchor, constant: -12),
        ])

        self.view = container
        restoreSortPreference()
    }

    func update(
        currentPath: String,
        entries: [RemoteFileEntry],
        isLoading: Bool,
        searchQuery: String
    ) {
        print("[FileManager][Detail] update path=\(currentPath) entries=\(entries.count) loading=\(isLoading) search=\(searchQuery)")
        self.currentPath = currentPath
        self.entries = entries
        self.isLoading = isLoading
        self.searchQuery = searchQuery
        tableView.reloadData()
        updateEmptyState()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filteredEntries[row]
        guard let columnID = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: columnID)
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("finder-detail-\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let result = NSTableCellView()
            result.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            result.textField = textField
            result.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            ])
            return result
        }()

        cell.textField?.font = column == .name ? .systemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 12)
        cell.textField?.stringValue = value(for: entry, column: column)
        cell.textField?.textColor = .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateEmptyState()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { return }
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
        persistSortPreference()
        tableView.reloadData()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue)
        else {
            return
        }
        defaults.set(tableColumn.width, forKey: widthDefaultsKey(for: column))
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 else { return }
        let entry = filteredEntries[row]
        print("[FileManager][Detail] doubleClick row=\(row) path=\(entry.path) isDirectory=\(entry.isDirectory)")
        if entry.isDirectory {
            onOpenDirectory(entry)
        } else {
            onOpenTextFile?(entry)
        }
    }

    private var filteredEntries: [RemoteFileEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [RemoteFileEntry]
        if trimmed.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.path.localizedCaseInsensitiveContains(trimmed)
        }
        }

        return filtered.sorted(by: compareEntries)
    }

    private func value(for entry: RemoteFileEntry, column: Column) -> String {
        switch column {
        case .name:
            return entry.name
        case .permission:
            if let permission = entry.permissions {
                return String(permission, radix: 8)
            }
            return "—"
        case .date:
            let formatter = DateFormatter()
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: entry.modifiedAt)
        case .size:
            return entry.isDirectory ? "—" : ByteSizeFormatter.format(entry.size)
        case .kind:
            return entry.isDirectory ? tr("Folder") : tr("File")
        }
    }

    private func updateEmptyState() {
        if isLoading {
            loadingIndicator.startAnimation(nil)
            emptyLabel.stringValue = tr("Loading directory...")
            emptyLabel.isHidden = false
            return
        }

        loadingIndicator.stopAnimation(nil)
        if filteredEntries.isEmpty {
            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            emptyLabel.stringValue = trimmed.isEmpty
                ? tr("No files in this directory.")
                : String(format: tr("No files or folders match “%@”."), trimmed)
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func selectedEntries() -> [RemoteFileEntry] {
        tableView.selectedRowIndexes.compactMap { index in
            guard index >= 0, index < filteredEntries.count else { return nil }
            return filteredEntries[index]
        }
    }

    private func clickedOrSelectedEntries() -> [RemoteFileEntry] {
        let clickedRow = tableView.clickedRow
        if clickedRow >= 0, clickedRow < filteredEntries.count {
            return [filteredEntries[clickedRow]]
        }
        return selectedEntries()
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: tr("Refresh"), action: #selector(handleRefresh), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("New Folder"), action: #selector(handleCreateDirectory), keyEquivalent: "")
        menu.addItem(withTitle: tr("New File"), action: #selector(handleCreateFile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Add current path"), action: #selector(handleAddCurrentQuickPath), keyEquivalent: "")
        menu.addItem(withTitle: tr("Upload To Current Directory"), action: #selector(handleUpload), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Rename"), action: #selector(handleRename), keyEquivalent: "")
        menu.addItem(withTitle: tr("Delete"), action: #selector(handleDelete), keyEquivalent: "")
        menu.addItem(withTitle: tr("Copy Path"), action: #selector(handleCopyPath), keyEquivalent: "")
        menu.addItem(withTitle: tr("Compress"), action: #selector(handleCompress), keyEquivalent: "")
        menu.addItem(withTitle: tr("Extract To"), action: #selector(handleExtract), keyEquivalent: "")
        menu.addItem(withTitle: tr("Edit"), action: #selector(handleOpenTextFile), keyEquivalent: "")
        menu.addItem(withTitle: tr("Live View"), action: #selector(handleOpenLogView), keyEquivalent: "")
        menu.addItem(withTitle: tr("Properties"), action: #selector(handleShowProperties), keyEquivalent: "")
        menu.addItem(withTitle: tr("Edit Permissions"), action: #selector(handleEditPermissions), keyEquivalent: "")
        return menu
    }

    @objc private func handleRefresh() {
        print("[FileManager][Detail] context refresh path=\(currentPath)")
        onRefresh()
    }

    @objc private func handleCreateDirectory() {
        print("[FileManager][Detail] context createDirectory path=\(currentPath)")
        onCreateDirectory(currentPath)
    }

    @objc private func handleCreateFile() {
        print("[FileManager][Detail] context createFile path=\(currentPath)")
        onCreateFile(currentPath)
    }

    @objc private func handleAddCurrentQuickPath() {
        print("[FileManager][Detail] context addQuickPath path=\(currentPath)")
        onAddCurrentQuickPath(currentPath)
    }

    @objc private func handleUpload() {
        print("[FileManager][Detail] context upload path=\(currentPath)")
        onUploadToDirectory(currentPath)
    }

    @objc private func handleRename() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        print("[FileManager][Detail] context rename path=\(entry.path)")
        onRenameEntry(entry)
    }

    @objc private func handleDelete() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        print("[FileManager][Detail] context delete count=\(entries.count)")
        onDeleteEntries(entries)
    }

    @objc private func handleCopyPath() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        print("[FileManager][Detail] context copyPath path=\(entry.path)")
        onCopyPath(entry.path)
    }

    @objc private func handleCompress() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        onCompressEntries?(entries)
    }

    @objc private func handleExtract() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        onExtractEntry?(entry)
    }

    @objc private func handleOpenTextFile() {
        guard let entry = clickedOrSelectedEntries().first, !entry.isDirectory else { return }
        print("[FileManager][Detail] context openText path=\(entry.path)")
        onOpenTextFile?(entry)
    }

    @objc private func handleOpenLogView() {
        guard let entry = clickedOrSelectedEntries().first, !entry.isDirectory else { return }
        print("[FileManager][Detail] context openLog path=\(entry.path)")
        onOpenLogView?(entry)
    }

    @objc private func handleShowProperties() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        print("[FileManager][Detail] context properties path=\(entry.path)")
        onShowProperties?(entry)
    }

    @objc private func handleEditPermissions() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        print("[FileManager][Detail] context permissions path=\(entry.path)")
        onEditPermissions?(entry)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = tableView.clickedRow
        if clickedRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let hasSelection = !clickedOrSelectedEntries().isEmpty
        for item in menu.items {
            switch item.action {
            case #selector(handleRename),
                 #selector(handleDelete),
                 #selector(handleCopyPath),
                 #selector(handleCompress),
                 #selector(handleExtract),
                 #selector(handleOpenTextFile),
                 #selector(handleOpenLogView),
                 #selector(handleShowProperties),
                 #selector(handleEditPermissions):
                item.isEnabled = hasSelection
            default:
                item.isEnabled = true
            }
        }
    }

    private func compareEntries(lhs: RemoteFileEntry, rhs: RemoteFileEntry) -> Bool {
        let comparison: ComparisonResult
        switch sortColumn {
        case .name:
            comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .permission:
            comparison = permissionText(for: lhs).localizedCaseInsensitiveCompare(permissionText(for: rhs))
        case .date:
            comparison = lhs.modifiedAt.compare(rhs.modifiedAt)
        case .size:
            comparison = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .kind:
            comparison = kindText(for: lhs).localizedCaseInsensitiveCompare(kindText(for: rhs))
        }

        if comparison == .orderedSame {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func permissionText(for entry: RemoteFileEntry) -> String {
        guard let permission = entry.permissions else { return "—" }
        return String(permission, radix: 8)
    }

    private func kindText(for entry: RemoteFileEntry) -> String {
        entry.isDirectory ? tr("Folder") : tr("File")
    }

    private func widthDefaultsKey(for column: Column) -> String {
        "remora.file-manager.column-width.\(column.rawValue)"
    }

    private func storedWidth(for column: Column) -> CGFloat? {
        let value = defaults.double(forKey: widthDefaultsKey(for: column))
        return value > 0 ? CGFloat(value) : nil
    }

    private func persistSortPreference() {
        defaults.set(sortColumn.rawValue, forKey: "remora.file-manager.sort-column")
        defaults.set(sortAscending, forKey: "remora.file-manager.sort-ascending")
    }

    private func restoreSortPreference() {
        if let storedColumn = defaults.string(forKey: "remora.file-manager.sort-column"),
           let column = Column(rawValue: storedColumn) {
            sortColumn = column
        }
        sortAscending = defaults.object(forKey: "remora.file-manager.sort-ascending") as? Bool ?? true
    }
}
