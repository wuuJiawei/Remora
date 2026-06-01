import AppKit
import RemoraCore

@MainActor
final class FileManagerWindowSplitController: NSSplitViewController {
    private let sidebarController: FileManagerOutlineSidebarController
    private let detailController: FileManagerFinderDetailController

    init(
        selectedPath: String,
        quickPathsProvider: @escaping () -> [HostQuickPath],
        directoriesProvider: @escaping () -> [RemoteFileEntry],
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
            directoriesProvider: directoriesProvider,
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
        sidebarController.selectedPath = selectedPath
        sidebarController.reload()
    }

    func reloadDetail(
        currentPath: String,
        entries: [RemoteFileEntry],
        isLoading: Bool,
        searchQuery: String
    ) {
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
    private let directoriesProvider: () -> [RemoteFileEntry]
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

    private enum Section: Int, CaseIterable {
        case quickPaths
        case folders
    }

    init(
        selectedPath: String,
        quickPathsProvider: @escaping () -> [HostQuickPath],
        directoriesProvider: @escaping () -> [RemoteFileEntry],
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
        self.directoriesProvider = directoriesProvider
        self.onSelectRoot = onSelectRoot
        self.onSelectQuickPath = onSelectQuickPath
        self.onSelectDirectory = onSelectDirectory
        self.onAddQuickPathForDirectory = onAddQuickPathForDirectory
        self.onRenameQuickPath = onRenameQuickPath
        self.onDeleteQuickPath = onDeleteQuickPath
        self.onReorderQuickPaths = onReorderQuickPaths
        self.onRefreshDirectory = onRefreshDirectory
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
        reload()
    }

    func reload() {
        outlineView.reloadData()
        outlineView.expandItem(Section.quickPaths.rawValue)
        outlineView.expandItem(Section.folders.rawValue)
        selectMatchingRow()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return Section.allCases.count }
        guard let raw = item as? Int, let section = Section(rawValue: raw) else { return 0 }
        switch section {
        case .quickPaths:
            return 1 + quickPathsProvider().count
        case .folders:
            return directoriesProvider().count
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Int).flatMap(Section.init(rawValue:)) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return Section.allCases[index].rawValue }
        guard let raw = item as? Int, let section = Section(rawValue: raw) else {
            return "__root__"
        }
        switch section {
        case .quickPaths:
            return index == 0 ? "__root__" : quickPathsProvider()[index - 1]
        case .folders:
            return directoriesProvider()[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

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

        if item as? String == "__root__" {
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

        if let directory = item as? RemoteFileEntry {
            cell.textField?.stringValue = directory.name
            cell.textField?.font = .systemFont(ofSize: 13, weight: .regular)
            cell.textField?.textColor = selectedPath == directory.path ? .controlAccentColor : .labelColor
            return cell
        }

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if item as? String == "__root__" {
            onSelectRoot()
        } else if let quickPath = item as? HostQuickPath {
            onSelectQuickPath(quickPath)
        } else if let directory = item as? RemoteFileEntry {
            onSelectDirectory(directory.path)
        }
    }

    @objc private func handleDoubleClick() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if item as? String == "__root__" {
            onSelectRoot()
        } else if let directory = item as? RemoteFileEntry {
            onSelectDirectory(directory.path)
        }
    }

    private func selectMatchingRow() {
        let rowCount = outlineView.numberOfRows
        for row in 0..<rowCount {
            let item = outlineView.item(atRow: row)
            if item as? String == "__root__", selectedPath == "/" {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
            if let quickPath = item as? HostQuickPath, quickPath.path == selectedPath {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
            if let directory = item as? RemoteFileEntry, directory.path == selectedPath {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
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
        onRefresh()
    }

    @objc private func handleCreateDirectory() {
        onCreateDirectory(currentPath)
    }

    @objc private func handleCreateFile() {
        onCreateFile(currentPath)
    }

    @objc private func handleAddCurrentQuickPath() {
        onAddCurrentQuickPath(currentPath)
    }

    @objc private func handleUpload() {
        onUploadToDirectory(currentPath)
    }

    @objc private func handleRename() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        onRenameEntry(entry)
    }

    @objc private func handleDelete() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        onDeleteEntries(entries)
    }

    @objc private func handleCopyPath() {
        guard let entry = clickedOrSelectedEntries().first else { return }
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
        onOpenTextFile?(entry)
    }

    @objc private func handleOpenLogView() {
        guard let entry = clickedOrSelectedEntries().first, !entry.isDirectory else { return }
        onOpenLogView?(entry)
    }

    @objc private func handleShowProperties() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        onShowProperties?(entry)
    }

    @objc private func handleEditPermissions() {
        guard let entry = clickedOrSelectedEntries().first else { return }
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
