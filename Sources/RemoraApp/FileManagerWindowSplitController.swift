import AppKit
import RemoraCore
import UniformTypeIdentifiers

// Primary native file manager browser implementation. New window-based file
// manager work should be routed here instead of FileManagerPanelView.
enum FileManagerContextCopyPathResolver {
    static func detailTargetPath(currentPath: String, clickedEntryPath: String?) -> String {
        let trimmedClickedPath = clickedEntryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedClickedPath, !trimmedClickedPath.isEmpty {
            return trimmedClickedPath
        }
        return currentPath
    }

    static func sidebarTargetPath(clickedItemPath: String?) -> String? {
        let trimmedClickedPath = clickedItemPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedClickedPath, !trimmedClickedPath.isEmpty else { return nil }
        return trimmedClickedPath
    }
}

enum FileManagerPasteTargetResolver {
    static func targetDirectory(currentPath: String, clickedEntry: RemoteFileEntry?) -> String {
        if let clickedEntry, clickedEntry.isDirectory {
            return clickedEntry.path
        }
        return currentPath
    }
}

private enum FileManagerContextMenuItemFactory {
    static func item(_ title: String, systemImage: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = image(systemName: systemImage)
        return item
    }

    static func submenu(_ title: String, systemImage: String, menu: NSMenu) -> NSMenuItem {
        let menuItem = item(title, systemImage: systemImage)
        menuItem.submenu = menu
        return menuItem
    }

    private static func image(systemName: String) -> NSImage? {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
    }
}

private enum FileManagerContextMenuSelectors {
    static let handleRefresh = NSSelectorFromString("handleRefresh")
    static let handleCreateDirectory = NSSelectorFromString("handleCreateDirectory")
    static let handleCreateFile = NSSelectorFromString("handleCreateFile")
    static let handleAddCurrentQuickPath = NSSelectorFromString("handleAddCurrentQuickPath")
    static let handleRemoveQuickPath = NSSelectorFromString("handleRemoveQuickPath")
    static let handleUpload = NSSelectorFromString("handleUpload")
    static let handleRename = NSSelectorFromString("handleRename")
    static let handleDelete = NSSelectorFromString("handleDelete")
    static let handleCopyPath = NSSelectorFromString("handleCopyPath")
    static let handleDownload = NSSelectorFromString("handleDownload")
    static let handleCopyEntries = NSSelectorFromString("handleCopyEntries")
    static let handleCutEntries = NSSelectorFromString("handleCutEntries")
    static let handlePasteEntries = NSSelectorFromString("handlePasteEntries")
    static let handleCloneEntry = NSSelectorFromString("handleCloneEntry")
    static let handleMoveEntries = NSSelectorFromString("handleMoveEntries")
    static let handleCompressTarGz = NSSelectorFromString("handleCompressTarGz")
    static let handleCompressTar = NSSelectorFromString("handleCompressTar")
    static let handleCompressZip = NSSelectorFromString("handleCompressZip")
    static let handleCompressSevenZip = NSSelectorFromString("handleCompressSevenZip")
    static let handleExtractToCurrentDirectory = NSSelectorFromString("handleExtractToCurrentDirectory")
    static let handleExtractToSameNameDirectory = NSSelectorFromString("handleExtractToSameNameDirectory")
    static let handleExtractToCustomDirectory = NSSelectorFromString("handleExtractToCustomDirectory")
    static let handleOpenTextFile = NSSelectorFromString("handleOpenTextFile")
    static let handleOpenLogView = NSSelectorFromString("handleOpenLogView")
    static let handleShowProperties = NSSelectorFromString("handleShowProperties")
    static let handleEditPermissions = NSSelectorFromString("handleEditPermissions")
}

private enum FileManagerContextMenuBuilder {
    struct Visibility {
        var refresh = true
        var new = true
        var transfer = true
        var upload = true
        var download = true
        var move = true
        var rename = true
        var delete = true
        var addCurrentPath = true
        var removeQuickPath = false
        var clipboard = true
        var copy = true
        var cut = true
        var paste = true
        var clone = true
        var copyPath = true
        var archive = true
        var compress = true
        var extract = true
        var openWith = true
        var info = true

        static let detail = Visibility()
        static let sidebar = Visibility(
            move: false,
            rename: false,
            delete: false,
            removeQuickPath: true,
            copy: false,
            cut: false,
            clone: false,
            extract: false,
            openWith: false
        )
    }

    struct Capabilities {
        var canModifySelection = false
        var canUseSelection = false
        var canArchiveSelection = false
        var canPaste = false
        var canExtract = false
        var canOpenFile = false
        var canShowInfo = false
        var canRemoveQuickPath = false
        var hideUnavailable = false
    }

    static func menu(visibility: Visibility = .detail) -> NSMenu {
        let menu = NSMenu()
        if visibility.refresh {
            menu.addItem(item(tr("Refresh"), icon: ContextMenuIconCatalog.refresh, action: FileManagerContextMenuSelectors.handleRefresh))
            menu.addItem(.separator())
        }

        if visibility.new {
            menu.addItem(
                submenu(tr("New"), icon: ContextMenuIconCatalog.newItems, menu: newSubmenu())
            )
        }
        if visibility.transfer, let transferMenu = transferSubmenu(visibility: visibility) {
            menu.addItem(
                submenu(tr("Transfer"), icon: ContextMenuIconCatalog.transfer, menu: transferMenu)
            )
        }

        if visibility.rename || visibility.delete {
            menu.addItem(.separator())
            if visibility.rename {
                menu.addItem(item(tr("Rename"), icon: ContextMenuIconCatalog.rename, action: FileManagerContextMenuSelectors.handleRename))
            }
            if visibility.delete {
                menu.addItem(item(tr("Delete"), icon: ContextMenuIconCatalog.delete, action: FileManagerContextMenuSelectors.handleDelete))
            }
        }

        menu.addItem(.separator())
        if visibility.addCurrentPath {
            menu.addItem(item(tr("Add current path"), icon: ContextMenuIconCatalog.quickPath, action: FileManagerContextMenuSelectors.handleAddCurrentQuickPath))
        }
        if visibility.removeQuickPath {
            menu.addItem(item(tr("Remove quick path"), icon: ContextMenuIconCatalog.delete, action: FileManagerContextMenuSelectors.handleRemoveQuickPath))
        }
        if visibility.clipboard, let clipboardMenu = clipboardSubmenu(visibility: visibility) {
            menu.addItem(
                submenu(tr("Clipboard"), icon: ContextMenuIconCatalog.clipboard, menu: clipboardMenu)
            )
        }
        if visibility.archive, let archiveMenu = archiveSubmenu(visibility: visibility) {
            menu.addItem(
                submenu(tr("Archive"), icon: ContextMenuIconCatalog.compress, menu: archiveMenu)
            )
        }
        if visibility.openWith {
            menu.addItem(
                submenu(tr("Open With"), icon: ContextMenuIconCatalog.openWith, menu: openWithSubmenu())
            )
        }
        if visibility.info {
            menu.addItem(
                submenu(tr("Info"), icon: ContextMenuIconCatalog.info, menu: infoSubmenu())
            )
        }
        return menu
    }

    @discardableResult
    static func update(_ menu: NSMenu, capabilities: Capabilities) -> Bool {
        update(menu.items, capabilities: capabilities)
    }

    private static func item(_ title: String, icon: String, action: Selector) -> NSMenuItem {
        FileManagerContextMenuItemFactory.item(title, systemImage: icon, action: action)
    }

    private static func submenu(_ title: String, icon: String, menu: NSMenu) -> NSMenuItem {
        FileManagerContextMenuItemFactory.submenu(title, systemImage: icon, menu: menu)
    }

    private static func newSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(tr("New Folder"), icon: ContextMenuIconCatalog.newFolder, action: FileManagerContextMenuSelectors.handleCreateDirectory))
        menu.addItem(item(tr("New File"), icon: ContextMenuIconCatalog.newFile, action: FileManagerContextMenuSelectors.handleCreateFile))
        return menu
    }

    private static func transferSubmenu(visibility: Visibility) -> NSMenu? {
        let menu = NSMenu()
        if visibility.upload {
            menu.addItem(item(tr("Upload To Current Directory"), icon: ContextMenuIconCatalog.upload, action: FileManagerContextMenuSelectors.handleUpload))
        }
        if visibility.download {
            menu.addItem(item(tr("Download"), icon: ContextMenuIconCatalog.download, action: FileManagerContextMenuSelectors.handleDownload))
        }
        if visibility.move {
            menu.addItem(item(tr("Move To"), icon: ContextMenuIconCatalog.moveTo, action: FileManagerContextMenuSelectors.handleMoveEntries))
        }
        return menu.items.isEmpty ? nil : menu
    }

    private static func clipboardSubmenu(visibility: Visibility) -> NSMenu? {
        let menu = NSMenu()
        if visibility.copy {
            menu.addItem(item(tr("Copy"), icon: ContextMenuIconCatalog.copy, action: FileManagerContextMenuSelectors.handleCopyEntries))
        }
        if visibility.cut {
            menu.addItem(item(tr("Cut"), icon: ContextMenuIconCatalog.cut, action: FileManagerContextMenuSelectors.handleCutEntries))
        }
        if visibility.paste {
            menu.addItem(item(tr("Paste"), icon: ContextMenuIconCatalog.paste, action: FileManagerContextMenuSelectors.handlePasteEntries))
        }
        if visibility.clone {
            menu.addItem(item(tr("Clone"), icon: ContextMenuIconCatalog.cloneSession, action: FileManagerContextMenuSelectors.handleCloneEntry))
        }
        if visibility.copyPath {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(item(tr("Copy Path"), icon: ContextMenuIconCatalog.copyPath, action: FileManagerContextMenuSelectors.handleCopyPath))
        }
        return menu.items.isEmpty ? nil : menu
    }

    private static func archiveSubmenu(visibility: Visibility) -> NSMenu? {
        let menu = NSMenu()
        if visibility.compress {
            menu.addItem(
                submenu(tr("Compress as..."), icon: ContextMenuIconCatalog.compress, menu: compressSubmenu())
            )
        }
        if visibility.extract {
            menu.addItem(
                submenu(tr("Extract"), icon: ContextMenuIconCatalog.extract, menu: extractSubmenu())
            )
        }
        return menu.items.isEmpty ? nil : menu
    }

    private static func compressSubmenu() -> NSMenu {
        let menu = NSMenu()
        let options: [(String, Selector)] = [
            ("TAR.GZ", FileManagerContextMenuSelectors.handleCompressTarGz),
            ("TAR", FileManagerContextMenuSelectors.handleCompressTar),
            ("ZIP", FileManagerContextMenuSelectors.handleCompressZip),
            ("7Z", FileManagerContextMenuSelectors.handleCompressSevenZip),
        ]
        for (title, selector) in options {
            menu.addItem(item(title, icon: ContextMenuIconCatalog.compress, action: selector))
        }
        return menu
    }

    private static func extractSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(tr("Extract to current directory"), icon: ContextMenuIconCatalog.extract, action: FileManagerContextMenuSelectors.handleExtractToCurrentDirectory))
        menu.addItem(item(tr("Extract to same-name folder"), icon: ContextMenuIconCatalog.newFolder, action: FileManagerContextMenuSelectors.handleExtractToSameNameDirectory))
        menu.addItem(item(tr("Extract to..."), icon: ContextMenuIconCatalog.moveTo, action: FileManagerContextMenuSelectors.handleExtractToCustomDirectory))
        return menu
    }

    private static func openWithSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(tr("Edit"), icon: ContextMenuIconCatalog.edit, action: FileManagerContextMenuSelectors.handleOpenTextFile))
        menu.addItem(item(tr("Live View"), icon: ContextMenuIconCatalog.liveView, action: FileManagerContextMenuSelectors.handleOpenLogView))
        return menu
    }

    private static func infoSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(tr("Properties"), icon: ContextMenuIconCatalog.properties, action: FileManagerContextMenuSelectors.handleShowProperties))
        menu.addItem(item(tr("Edit Permissions"), icon: ContextMenuIconCatalog.permissions, action: FileManagerContextMenuSelectors.handleEditPermissions))
        return menu
    }

    @discardableResult
    private static func update(_ items: [NSMenuItem], capabilities: Capabilities) -> Bool {
        var hasVisibleItem = false
        for item in items {
            if let submenu = item.submenu {
                let hasVisibleChild = update(submenu.items, capabilities: capabilities)
                item.isHidden = capabilities.hideUnavailable && !hasVisibleChild
                hasVisibleItem = hasVisibleItem || !item.isHidden
                continue
            }
            switch item.action {
            case FileManagerContextMenuSelectors.handleRename,
                 FileManagerContextMenuSelectors.handleDelete,
                 FileManagerContextMenuSelectors.handleCutEntries,
                 FileManagerContextMenuSelectors.handleMoveEntries:
                item.isEnabled = capabilities.canModifySelection
            case FileManagerContextMenuSelectors.handleDownload,
                 FileManagerContextMenuSelectors.handleCopyEntries,
                 FileManagerContextMenuSelectors.handleCloneEntry:
                item.isEnabled = capabilities.canUseSelection
            case FileManagerContextMenuSelectors.handleCompressTarGz,
                 FileManagerContextMenuSelectors.handleCompressTar,
                 FileManagerContextMenuSelectors.handleCompressZip,
                 FileManagerContextMenuSelectors.handleCompressSevenZip:
                item.isEnabled = capabilities.canArchiveSelection
            case FileManagerContextMenuSelectors.handleExtractToCurrentDirectory,
                 FileManagerContextMenuSelectors.handleExtractToSameNameDirectory,
                 FileManagerContextMenuSelectors.handleExtractToCustomDirectory:
                item.isEnabled = capabilities.canExtract
            case FileManagerContextMenuSelectors.handleOpenTextFile,
                 FileManagerContextMenuSelectors.handleOpenLogView:
                item.isEnabled = capabilities.canOpenFile
            case FileManagerContextMenuSelectors.handleShowProperties,
                 FileManagerContextMenuSelectors.handleEditPermissions:
                item.isEnabled = capabilities.canShowInfo
            case FileManagerContextMenuSelectors.handlePasteEntries:
                item.isEnabled = capabilities.canPaste
            case FileManagerContextMenuSelectors.handleRemoveQuickPath:
                item.isEnabled = capabilities.canRemoveQuickPath
            default:
                item.isEnabled = true
            }
            if item.isSeparatorItem {
                item.isHidden = false
            } else if capabilities.hideUnavailable {
                item.isHidden = !item.isEnabled
            } else {
                item.isHidden = false
            }
            hasVisibleItem = hasVisibleItem || (!item.isHidden && !item.isSeparatorItem)
        }
        hideRedundantSeparators(items)
        return hasVisibleItem
    }

    private static func hideRedundantSeparators(_ items: [NSMenuItem]) {
        var hasVisibleContentBeforeSeparator = false
        var pendingSeparators: [NSMenuItem] = []
        for item in items {
            if item.isHidden {
                continue
            }
            if item.isSeparatorItem {
                pendingSeparators.append(item)
                item.isHidden = true
                continue
            }
            if hasVisibleContentBeforeSeparator {
                pendingSeparators.last?.isHidden = false
            }
            pendingSeparators.removeAll()
            hasVisibleContentBeforeSeparator = true
        }
        for separator in pendingSeparators {
            separator.isHidden = true
        }
    }
}

@MainActor
final class FileManagerWindowSplitController: NSSplitViewController {
    enum ExtractDestinationAction: String, Sendable {
        case currentDirectory
        case sameNameDirectory
        case customDirectory
    }

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
        onDownloadEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCutEntries: @escaping ([RemoteFileEntry]) -> Void,
        canPasteIntoDirectory: @escaping (String) -> Bool,
        onPasteIntoDirectory: @escaping (String) -> Void,
        onCloneEntry: @escaping (RemoteFileEntry) -> Void,
        onMoveEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyPath: @escaping (String) -> Void,
        onUploadToDirectory: @escaping (String) -> Void,
        onUploadLocalFiles: @escaping ([URL], String) -> Void
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
            onRefreshDirectory: onRefreshDirectory,
            onCreateDirectory: onCreateDirectory,
            onCreateFile: onCreateFile,
            onRenameEntry: onRenameEntry,
            onDeleteEntries: onDeleteEntries,
            onDownloadEntries: onDownloadEntries,
            onCopyEntries: onCopyEntries,
            onCutEntries: onCutEntries,
            canPasteIntoDirectory: canPasteIntoDirectory,
            onPasteIntoDirectory: onPasteIntoDirectory,
            onCloneEntry: onCloneEntry,
            onMoveEntries: onMoveEntries,
            onCopyPath: onCopyPath,
            onUploadToDirectory: onUploadToDirectory
        )
        self.detailController = FileManagerFinderDetailController(
            onOpenDirectory: onOpenDirectory,
            onRefresh: onRefreshCurrentDirectory,
            onAddCurrentQuickPath: onAddCurrentQuickPath,
            onCreateDirectory: onCreateDirectory,
            onCreateFile: onCreateFile,
            onRenameEntry: onRenameEntry,
            onDeleteEntries: onDeleteEntries,
            onDownloadEntries: onDownloadEntries,
            onCopyEntries: onCopyEntries,
            onCutEntries: onCutEntries,
            canPasteIntoDirectory: canPasteIntoDirectory,
            onPasteIntoDirectory: onPasteIntoDirectory,
            onCloneEntry: onCloneEntry,
            onMoveEntries: onMoveEntries,
            onCopyPath: onCopyPath,
            onUploadToDirectory: onUploadToDirectory,
            onUploadLocalFiles: onUploadLocalFiles
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
        LogManager.debug(.fileManager, "sidebar reload requested selectedPath=\(selectedPath)")
        sidebarController.selectedPath = selectedPath
        sidebarController.reload()
    }

    func refreshSidebarQuickPaths() {
        sidebarController.reloadQuickPaths()
    }

    func updateSidebarSelection(selectedPath: String) {
        sidebarController.updateSelection(selectedPath: selectedPath)
    }

    func updateSidebarDirectorySnapshot(path: String, entries: [RemoteFileEntry]) {
        sidebarController.updateDirectorySnapshot(path: path, entries: entries)
    }

    func reloadDetail(
        currentPath: String,
        entries: [RemoteFileEntry],
        isLoading: Bool,
        searchQuery: String,
        transferProgress: Double? = nil
    ) {
        LogManager.debug(
            .fileManager,
            "detail reload path=\(currentPath) entries=\(entries.count) loading=\(isLoading) search=\(searchQuery)"
        )
        detailController.update(
            currentPath: currentPath,
            entries: entries,
            isLoading: isLoading,
            searchQuery: searchQuery,
            transferProgress: transferProgress
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
        sidebarController.onShowProperties = onShowProperties
        sidebarController.onEditPermissions = onEditPermissions
        detailController.onShowProperties = onShowProperties
        detailController.onEditPermissions = onEditPermissions
    }

    func setOpenHandlers(
        onOpenTextFile: @escaping (RemoteFileEntry) -> Void,
        onOpenLogView: @escaping (RemoteFileEntry) -> Void
    ) {
        sidebarController.onOpenTextFile = onOpenTextFile
        sidebarController.onOpenLogView = onOpenLogView
        detailController.onOpenTextFile = onOpenTextFile
        detailController.onOpenLogView = onOpenLogView
    }

    func setArchiveHandlers(
        onCompressEntries: @escaping ([RemoteFileEntry], ArchiveFormat) -> Void,
        onExtractEntry: @escaping (RemoteFileEntry, ExtractDestinationAction) -> Void
    ) {
        sidebarController.onCompressEntries = onCompressEntries
        sidebarController.onExtractEntry = onExtractEntry
        detailController.onCompressEntries = onCompressEntries
        detailController.onExtractEntry = onExtractEntry
    }
}

@MainActor
private final class FileManagerOutlineSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
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
    private let onCreateDirectory: (String) -> Void
    private let onCreateFile: (String) -> Void
    private let onRenameEntry: (RemoteFileEntry) -> Void
    private let onDeleteEntries: ([RemoteFileEntry]) -> Void
    private let onDownloadEntries: ([RemoteFileEntry]) -> Void
    private let onCopyEntries: ([RemoteFileEntry]) -> Void
    private let onCutEntries: ([RemoteFileEntry]) -> Void
    private let canPasteIntoDirectory: (String) -> Bool
    private let onPasteIntoDirectory: (String) -> Void
    private let onCloneEntry: (RemoteFileEntry) -> Void
    private let onMoveEntries: ([RemoteFileEntry]) -> Void
    private let onCopyPath: (String) -> Void
    private let onUploadToDirectory: (String) -> Void
    var onEditPermissions: ((RemoteFileEntry) -> Void)?
    var onShowProperties: ((RemoteFileEntry) -> Void)?
    var onOpenTextFile: ((RemoteFileEntry) -> Void)?
    var onOpenLogView: ((RemoteFileEntry) -> Void)?
    var onCompressEntries: (([RemoteFileEntry], ArchiveFormat) -> Void)?
    var onExtractEntry: ((RemoteFileEntry, FileManagerWindowSplitController.ExtractDestinationAction) -> Void)?

    private let outlineView = NSOutlineView()
    private var scrollView: NSScrollView!
    private var quickPathDropTargetID: UUID?
    private var isSelectingProgrammatically = false
    private let rootDirectoryNode = DirectoryNode(path: "/")
    private var directoryNodeCache: [String: DirectoryNode] = [:]
    private var directoryLoadTasks: [String: Task<Result<[RemoteFileEntry], Error>, Never>] = [:]
    private var selectionSyncTask: Task<Void, Never>?
    private var expandedDirectoryPaths: Set<String> = []
    private var programmaticExpansionPaths: Set<String> = []

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
        onRefreshDirectory: @escaping (String) -> Void,
        onCreateDirectory: @escaping (String) -> Void,
        onCreateFile: @escaping (String) -> Void,
        onRenameEntry: @escaping (RemoteFileEntry) -> Void,
        onDeleteEntries: @escaping ([RemoteFileEntry]) -> Void,
        onDownloadEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCutEntries: @escaping ([RemoteFileEntry]) -> Void,
        canPasteIntoDirectory: @escaping (String) -> Bool,
        onPasteIntoDirectory: @escaping (String) -> Void,
        onCloneEntry: @escaping (RemoteFileEntry) -> Void,
        onMoveEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyPath: @escaping (String) -> Void,
        onUploadToDirectory: @escaping (String) -> Void
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
        self.onCreateDirectory = onCreateDirectory
        self.onCreateFile = onCreateFile
        self.onRenameEntry = onRenameEntry
        self.onDeleteEntries = onDeleteEntries
        self.onDownloadEntries = onDownloadEntries
        self.onCopyEntries = onCopyEntries
        self.onCutEntries = onCutEntries
        self.canPasteIntoDirectory = canPasteIntoDirectory
        self.onPasteIntoDirectory = onPasteIntoDirectory
        self.onCloneEntry = onCloneEntry
        self.onMoveEntries = onMoveEntries
        self.onCopyPath = onCopyPath
        self.onUploadToDirectory = onUploadToDirectory
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
        outlineView.menu = buildContextMenu()

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
        LogManager.debug(.fileManager, "sidebar viewDidLoad")
        reload()
    }

    func reload() {
        selectedPath = Self.normalizePath(selectedPath)
        LogManager.debug(
            .fileManager,
            "sidebar reload selectedPath=\(selectedPath) quickPaths=\(quickPathsProvider().count) expandedTracked=\(expandedDirectoryPaths.count)"
        )
        selectionSyncTask?.cancel()
        outlineView.reloadData()
        outlineView.expandItem(Section.quickPaths.rawValue)
        outlineView.expandItem(Section.folders.rawValue)
        restoreExpandedNodes()
        ensureRootChildrenLoadedIfNeeded()
        syncSelectionToSelectedPath()
    }

    func updateSelection(selectedPath: String) {
        self.selectedPath = Self.normalizePath(selectedPath)
        LogManager.debug(.fileManager, "sidebar updateSelection selectedPath=\(self.selectedPath)")
        refreshRowColors()
        syncSelectionToSelectedPath()
    }

    func reloadQuickPaths() {
        LogManager.debug(.fileManager, "sidebar reloadQuickPaths quickPaths=\(quickPathsProvider().count)")
        outlineView.reloadItem(Section.quickPaths.rawValue, reloadChildren: true)
        _ = selectPreferredMatchingRow()
    }

    func updateDirectorySnapshot(path: String, entries: [RemoteFileEntry]) {
        LogManager.debug(.fileManager, "sidebar snapshot path=\(path) entries=\(entries.count)")
        guard snapshotMatchesDirectory(path: path, entries: entries) else {
            LogManager.error(.fileManager, "sidebar snapshot rejected path=\(path) entries=\(entries.count)")
            return
        }
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

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let directory = item as? DirectoryNode else { return true }
        if programmaticExpansionPaths.remove(directory.path) != nil {
            LogManager.debug(.fileManager, "sidebar shouldExpand allow programmatic path=\(directory.path)")
            return true
        }
        if outlineView.isItemExpanded(directory) {
            LogManager.debug(.fileManager, "sidebar shouldExpand ignored alreadyExpanded path=\(directory.path)")
            return false
        }
        expandedDirectoryPaths.insert(directory.path)
        let row = outlineView.row(forItem: directory)
        switch directory.childrenState {
        case .loaded:
            LogManager.debug(
                .fileManager,
                "sidebar shouldExpand allow loaded path=\(directory.path) row=\(row) rowCount=\(outlineView.numberOfRows)"
            )
            return true
        case .loading:
            LogManager.debug(
                .fileManager,
                "sidebar shouldExpand defer loading path=\(directory.path) row=\(row) rowCount=\(outlineView.numberOfRows)"
            )
            return false
        case .unloaded:
            LogManager.debug(
                .fileManager,
                "sidebar shouldExpand defer until loaded path=\(directory.path) row=\(row) rowCount=\(outlineView.numberOfRows)"
            )
            let path = directory.path
            Task { [weak self] in
                _ = await self?.loadChildrenIfNeeded(forPath: path, expandAfterLoad: true, reason: "userExpand")
            }
            return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let directory = item as? DirectoryNode else { return true }
        expandedDirectoryPaths.remove(directory.path)
        LogManager.debug(.fileManager, "sidebar shouldCollapse path=\(directory.path) rowCount=\(outlineView.numberOfRows)")
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FileManagerSidebarRowView()
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
            cell.textField?.textColor = textColor(for: item, isCurrentPath: selectedPath == "/")
            return cell
        }

        if let quickPath = item as? HostQuickPath {
            cell.textField?.stringValue = quickPath.name
            cell.textField?.font = .systemFont(ofSize: 13, weight: .regular)
            cell.textField?.textColor = textColor(for: item, isCurrentPath: selectedPath == quickPath.path)
            return cell
        }

        if let directory = item as? DirectoryNode {
            cell.textField?.stringValue = directory.displayName
            cell.textField?.font = .systemFont(ofSize: 13, weight: .regular)
            cell.textField?.textColor = textColor(for: item, isCurrentPath: selectedPath == directory.path)
            return cell
        }

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshRowColors()
        if isSelectingProgrammatically {
            LogManager.debug(.fileManager, "sidebar selection ignored programmatic")
            return
        }
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        LogManager.debug(.fileManager, "sidebar selection row=\(row) selectedPath=\(selectedPath)")
        if item as? String == SidebarItemID.root {
            if selectedPath == "/" {
                LogManager.debug(.fileManager, "sidebar selection skip root reselect")
                return
            }
            onSelectRoot()
        } else if let quickPath = item as? HostQuickPath {
            if quickPath.path == selectedPath {
                LogManager.debug(.fileManager, "sidebar selection skip quickPath reselect path=\(quickPath.path)")
                return
            }
            onSelectQuickPath(quickPath)
        } else if let directory = item as? DirectoryNode {
            if directory.path == selectedPath {
                LogManager.debug(.fileManager, "sidebar selection skip directory reselect path=\(directory.path)")
                return
            }
            onSelectDirectory(directory.path)
        }
    }

    @objc private func handleDoubleClick() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        LogManager.debug(.fileManager, "sidebar doubleClick row=\(row)")
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
            _ = await self.loadChildrenIfNeeded(forPath: rootPath, reason: "rootBootstrap")
        }
    }

    private func syncSelectionToSelectedPath() {
        if selectPreferredMatchingRow() {
            return
        }

        let targetPath = selectedPath
        LogManager.debug(.fileManager, "sidebar syncSelection targetPath=\(targetPath)")
        selectionSyncTask = Task { [weak self] in
            guard let self else { return }
            await self.expandAndSelectDirectory(path: targetPath)
        }
    }

    private func selectPreferredMatchingRow() -> Bool {
        let rowCount = outlineView.numberOfRows
        isSelectingProgrammatically = true
        defer { isSelectingProgrammatically = false }
        for row in 0..<rowCount {
            let item = outlineView.item(atRow: row)
            if let directory = item as? DirectoryNode, directory.path == selectedPath {
                LogManager.debug(.fileManager, "sidebar selectPreferred directory row=\(row) path=\(directory.path)")
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return true
            }
        }
        for row in 0..<rowCount {
            let item = outlineView.item(atRow: row)
            if let quickPath = item as? HostQuickPath, quickPath.path == selectedPath {
                LogManager.debug(.fileManager, "sidebar selectPreferred quickPath row=\(row) path=\(quickPath.path)")
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return true
            }
            if item as? String == SidebarItemID.root, selectedPath == "/" {
                LogManager.debug(.fileManager, "sidebar selectPreferred root row=\(row)")
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return true
            }
        }
        return false
    }

    private func expandAndSelectDirectory(path: String) async {
        let normalizedPath = Self.normalizePath(path)
        guard normalizedPath != "/", !Task.isCancelled else { return }
        LogManager.debug(.fileManager, "sidebar expandAndSelect path=\(normalizedPath)")

        let components = ancestorPaths(for: normalizedPath)
        guard !components.isEmpty else { return }

        var parent = rootDirectoryNode
        for (index, componentPath) in components.enumerated() {
            let children = await loadChildrenIfNeeded(forPath: parent.path, reason: "syncSelectionParent")
            guard !Task.isCancelled else { return }
            guard let nextNode = children.first(where: { $0.path == componentPath }) else { return }

            if index < components.count - 1 {
                await ensureExpanded(nextNode, reason: "syncSelectionAncestor")
            }
            parent = nextNode
        }

        guard !Task.isCancelled else { return }
        selectDirectoryNode(parent)
    }

    private func selectDirectoryNode(_ node: DirectoryNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        LogManager.debug(.fileManager, "sidebar selectDirectoryNode path=\(node.path) row=\(row)")
        isSelectingProgrammatically = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isSelectingProgrammatically = false
        refreshRowColors()
    }

    private func loadChildrenIfNeeded(
        forPath path: String,
        expandAfterLoad: Bool = false,
        reason: String = "normal"
    ) async -> [DirectoryNode] {
        let node = directoryNode(forPath: path)
        if node.childrenState == .loaded {
            LogManager.debug(
                .fileManager,
                "sidebar loadChildren cacheHit path=\(path) children=\(node.children.count) reason=\(reason) expandAfterLoad=\(expandAfterLoad)"
            )
            if expandAfterLoad {
                programmaticExpandIfNeeded(node, reason: reason)
            }
            return node.children
        }

        let normalizedPath = node.path
        let task: Task<Result<[RemoteFileEntry], Error>, Never>
        if let existingTask = directoryLoadTasks[normalizedPath] {
            LogManager.debug(
                .fileManager,
                "sidebar loadChildren joinInFlight path=\(normalizedPath) reason=\(reason) expandAfterLoad=\(expandAfterLoad)"
            )
            task = existingTask
        } else {
            node.childrenState = .loading
            LogManager.debug(
                .fileManager,
                "sidebar loadChildren start path=\(normalizedPath) reason=\(reason) expandAfterLoad=\(expandAfterLoad)"
            )
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
            if case let .failure(error) = result {
                LogManager.error(.fileManager, "sidebar loadChildren failed path=\(normalizedPath) error=\(error.localizedDescription)")
            } else {
                LogManager.error(.fileManager, "sidebar loadChildren failed path=\(normalizedPath)")
            }
            return node.children
        }
        LogManager.debug(
            .fileManager,
            "sidebar loadChildren success path=\(normalizedPath) children=\(entries.count) reason=\(reason) expandAfterLoad=\(expandAfterLoad)"
        )
        applyDirectorySnapshot(path: normalizedPath, entries: entries)
        if expandAfterLoad {
            programmaticExpandIfNeeded(node, reason: reason)
        }
        return node.children
    }

    private func applyDirectorySnapshot(path: String, entries: [RemoteFileEntry]) {
        let normalizedPath = Self.normalizePath(path)
        let node = directoryNode(forPath: normalizedPath)
        let childDirectories = entries.filter(\.isDirectory)
        var acceptedChildPaths: [String] = []
        var seenPaths = Set<String>()
        node.children = childDirectories.compactMap { entry in
            let childPath = Self.normalizePath(entry.path)
            guard childPath != normalizedPath else {
                LogManager.error(.fileManager, "sidebar applySnapshot reject selfChild parent=\(normalizedPath) child=\(childPath)")
                return nil
            }
            guard !childPath.hasPrefix("\(normalizedPath)/\(URL(fileURLWithPath: normalizedPath).lastPathComponent)/") else {
                LogManager.error(.fileManager, "sidebar applySnapshot reject suspiciousLoop parent=\(normalizedPath) child=\(childPath)")
                return nil
            }
            guard seenPaths.insert(childPath).inserted else {
                LogManager.debug(.fileManager, "sidebar applySnapshot skip duplicate parent=\(normalizedPath) child=\(childPath)")
                return nil
            }

            acceptedChildPaths.append(childPath)
            let childNode = directoryNode(forPath: childPath, displayName: entry.name)
            childNode.displayName = entry.name
            return childNode
        }
        let sample = acceptedChildPaths.prefix(8).joined(separator: ",")
        LogManager.debug(
            .fileManager,
            "sidebar applySnapshot path=\(normalizedPath) childDirectories=\(childDirectories.count) accepted=\(acceptedChildPaths.count) sample=[\(sample)]"
        )
        node.childrenState = .loaded

        if normalizedPath == rootDirectoryNode.path {
            outlineView.reloadItem(Section.folders.rawValue, reloadChildren: true)
        } else {
            outlineView.reloadItem(node, reloadChildren: true)
        }
        restoreExpandedNodes()
    }

    private func snapshotMatchesDirectory(path: String, entries: [RemoteFileEntry]) -> Bool {
        let normalizedPath = Self.normalizePath(path)
        let expectedPrefix = normalizedPath == "/" ? "/" : "\(normalizedPath)/"

        for entry in entries {
            let entryPath = Self.normalizePath(entry.path)
            guard entryPath != normalizedPath else {
                LogManager.error(.fileManager, "sidebar snapshot mismatch samePath path=\(normalizedPath) entry=\(entryPath)")
                return false
            }
            guard entryPath.hasPrefix(expectedPrefix) else {
                LogManager.error(.fileManager, "sidebar snapshot mismatch prefix path=\(normalizedPath) entry=\(entryPath)")
                return false
            }

            let relative = String(entryPath.dropFirst(expectedPrefix.count))
            if relative.contains("/") {
                LogManager.error(.fileManager, "sidebar snapshot mismatch nested path=\(normalizedPath) entry=\(entryPath)")
                return false
            }
        }

        return true
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
            let row = outlineView.row(forItem: node)
            if row < 0 {
                LogManager.debug(.fileManager, "sidebar restoreExpanded skip invisible path=\(path)")
                continue
            }
            guard !outlineView.isItemExpanded(node) else {
                LogManager.debug(.fileManager, "sidebar restoreExpanded skip alreadyExpanded path=\(path)")
                continue
            }
            LogManager.debug(.fileManager, "sidebar restoreExpanded path=\(path) row=\(row)")
            requestExpansionIfNeeded(for: node, reason: "restoreExpanded")
        }
    }

    private func ensureExpanded(_ node: DirectoryNode, reason: String) async {
        if outlineView.isItemExpanded(node) {
            LogManager.debug(.fileManager, "sidebar ensureExpanded skip alreadyExpanded path=\(node.path) reason=\(reason)")
            return
        }
        switch node.childrenState {
        case .loaded:
            programmaticExpandIfNeeded(node, reason: reason)
        case .loading, .unloaded:
            _ = await loadChildrenIfNeeded(forPath: node.path, expandAfterLoad: true, reason: reason)
        }
    }

    private func requestExpansionIfNeeded(for node: DirectoryNode, reason: String) {
        switch node.childrenState {
        case .loaded:
            programmaticExpandIfNeeded(node, reason: reason)
        case .loading:
            LogManager.debug(.fileManager, "sidebar requestExpansion waiting path=\(node.path) reason=\(reason)")
        case .unloaded:
            let path = node.path
            LogManager.debug(.fileManager, "sidebar requestExpansion loadFirst path=\(path) reason=\(reason)")
            Task { [weak self] in
                _ = await self?.loadChildrenIfNeeded(forPath: path, expandAfterLoad: true, reason: reason)
            }
        }
    }

    private func programmaticExpandIfNeeded(_ node: DirectoryNode, reason: String) {
        guard !outlineView.isItemExpanded(node) else {
            LogManager.debug(.fileManager, "sidebar programmaticExpand skip alreadyExpanded path=\(node.path) reason=\(reason)")
            return
        }
        if !programmaticExpansionPaths.insert(node.path).inserted {
            LogManager.debug(.fileManager, "sidebar programmaticExpand skip pending path=\(node.path) reason=\(reason)")
            return
        }
        LogManager.debug(.fileManager, "sidebar programmaticExpand path=\(node.path) reason=\(reason)")
        outlineView.expandItem(node)
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

    private func textColor(for item: Any, isCurrentPath: Bool) -> NSColor {
        let row = outlineView.row(forItem: item)
        if row >= 0, outlineView.selectedRowIndexes.contains(row) {
            return .alternateSelectedControlTextColor
        }
        return isCurrentPath ? .labelColor : .labelColor
    }

    private func refreshRowColors() {
        let rows = IndexSet(integersIn: 0..<outlineView.numberOfRows)
        guard !rows.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    private func buildContextMenu() -> NSMenu {
        let menu = FileManagerContextMenuBuilder.menu(visibility: .sidebar)
        menu.delegate = self
        return menu
    }

    private func selectedSidebarItem() -> Any? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row)
    }

    private func selectedSidebarPath() -> String? {
        if selectedSidebarItem() as? String == SidebarItemID.root {
            return "/"
        }
        if let quickPath = selectedSidebarItem() as? HostQuickPath {
            return quickPath.path
        }
        if let directory = selectedSidebarItem() as? DirectoryNode {
            return directory.path
        }
        return nil
    }

    private func selectedSidebarEntry() -> RemoteFileEntry? {
        guard let path = selectedSidebarPath() else { return nil }
        return RemoteFileEntry(
            name: Self.defaultDisplayName(for: path),
            path: path,
            size: 0,
            isDirectory: true
        )
    }

    private func selectedSidebarIsRoot() -> Bool {
        selectedSidebarPath() == "/"
    }

    private func selectedSidebarIsQuickPath() -> Bool {
        selectedSidebarItem() is HostQuickPath
    }

    @objc private func handleRefresh() {
        guard let path = selectedSidebarPath() else { return }
        LogManager.debug(.fileManager, "sidebar context refresh path=\(path)")
        onRefreshDirectory(path)
    }

    @objc private func handleCreateDirectory() {
        guard let path = selectedSidebarPath() else { return }
        LogManager.debug(.fileManager, "sidebar context createDirectory path=\(path)")
        onCreateDirectory(path)
    }

    @objc private func handleCreateFile() {
        guard let path = selectedSidebarPath() else { return }
        LogManager.debug(.fileManager, "sidebar context createFile path=\(path)")
        onCreateFile(path)
    }

    @objc private func handleAddCurrentQuickPath() {
        guard let path = selectedSidebarPath() else { return }
        LogManager.debug(.fileManager, "sidebar context addQuickPath path=\(path)")
        onAddQuickPathForDirectory(path)
    }

    @objc private func handleRemoveQuickPath() {
        guard let quickPath = selectedSidebarItem() as? HostQuickPath else { return }
        onDeleteQuickPath(quickPath)
    }

    @objc private func handleUpload() {
        guard let path = selectedSidebarPath() else { return }
        LogManager.debug(.fileManager, "sidebar context upload path=\(path)")
        onUploadToDirectory(path)
    }

    @objc private func handleRename() {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot(), !selectedSidebarIsQuickPath() else { return }
        LogManager.debug(.fileManager, "sidebar context rename path=\(entry.path)")
        onRenameEntry(entry)
    }

    @objc private func handleDelete() {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot(), !selectedSidebarIsQuickPath() else { return }
        LogManager.debug(.fileManager, "sidebar context delete path=\(entry.path)")
        onDeleteEntries([entry])
    }

    @objc private func handleCopyPath() {
        guard let targetPath = sidebarCopyPathTarget() else { return }
        LogManager.debug(.fileManager, "sidebar context copyPath path=\(targetPath)")
        onCopyPath(targetPath)
    }

    @objc private func handleDownload() {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot() else { return }
        LogManager.debug(.fileManager, "sidebar context download path=\(entry.path)")
        onDownloadEntries([entry])
    }

    @objc private func handleCopyEntries() {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot() else { return }
        onCopyEntries([entry])
    }

    @objc private func handleCutEntries() {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot(), !selectedSidebarIsQuickPath() else { return }
        onCutEntries([entry])
    }

    @objc private func handlePasteEntries() {
        guard let path = selectedSidebarPath() else { return }
        onPasteIntoDirectory(path)
    }

    @objc private func handleCloneEntry() {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot() else { return }
        onCloneEntry(entry)
    }

    @objc private func handleMoveEntries() {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot(), !selectedSidebarIsQuickPath() else { return }
        onMoveEntries([entry])
    }

    @objc private func handleCompressTarGz() {
        handleCompress(format: .tarGz)
    }

    @objc private func handleCompressTar() {
        handleCompress(format: .tar)
    }

    @objc private func handleCompressZip() {
        handleCompress(format: .zip)
    }

    @objc private func handleCompressSevenZip() {
        handleCompress(format: .sevenZip)
    }

    private func handleCompress(format: ArchiveFormat) {
        guard let entry = selectedSidebarEntry(), !selectedSidebarIsRoot() else { return }
        onCompressEntries?([entry], format)
    }

    @objc private func handleExtractToCurrentDirectory() {
        handleExtract(action: .currentDirectory)
    }

    @objc private func handleExtractToSameNameDirectory() {
        handleExtract(action: .sameNameDirectory)
    }

    @objc private func handleExtractToCustomDirectory() {
        handleExtract(action: .customDirectory)
    }

    private func handleExtract(action: FileManagerWindowSplitController.ExtractDestinationAction) {
        guard let entry = selectedSidebarEntry() else { return }
        onExtractEntry?(entry, action)
    }

    @objc private func handleOpenTextFile() {
        guard let entry = selectedSidebarEntry(), !entry.isDirectory else { return }
        onOpenTextFile?(entry)
    }

    @objc private func handleOpenLogView() {
        guard let entry = selectedSidebarEntry(), !entry.isDirectory else { return }
        onOpenLogView?(entry)
    }

    @objc private func handleShowProperties() {
        guard let entry = selectedSidebarEntry() else { return }
        LogManager.debug(.fileManager, "sidebar context properties path=\(entry.path)")
        onShowProperties?(entry)
    }

    @objc private func handleEditPermissions() {
        guard let entry = selectedSidebarEntry() else { return }
        LogManager.debug(.fileManager, "sidebar context permissions path=\(entry.path)")
        onEditPermissions?(entry)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = outlineView.clickedRow
        if clickedRow >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        guard selectedSidebarPath() != nil else { return }
        let isRoot = selectedSidebarIsRoot()
        let isQuickPath = selectedSidebarIsQuickPath()
        let canModifySelection = !isRoot && !isQuickPath
        let canUseSelection = !isRoot
        FileManagerContextMenuBuilder.update(
            menu,
            capabilities: FileManagerContextMenuBuilder.Capabilities(
                canModifySelection: canModifySelection,
                canUseSelection: canUseSelection,
                canArchiveSelection: canUseSelection && !isQuickPath,
                canPaste: selectedSidebarPath().map(canPasteIntoDirectory) ?? false,
                canExtract: false,
                canOpenFile: false,
                canShowInfo: true,
                canRemoveQuickPath: isQuickPath,
                hideUnavailable: true
            )
        )
    }

    private func sidebarCopyPathTarget() -> String? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        let item = outlineView.item(atRow: row)
        if item as? String == SidebarItemID.root {
            return FileManagerContextCopyPathResolver.sidebarTargetPath(clickedItemPath: "/")
        }
        if let quickPath = item as? HostQuickPath {
            return FileManagerContextCopyPathResolver.sidebarTargetPath(clickedItemPath: quickPath.path)
        }
        if let directory = item as? DirectoryNode {
            return FileManagerContextCopyPathResolver.sidebarTargetPath(clickedItemPath: directory.path)
        }
        return nil
    }
}

@MainActor
private final class FileManagerSidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
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
    private let onDownloadEntries: ([RemoteFileEntry]) -> Void
    private let onCopyEntries: ([RemoteFileEntry]) -> Void
    private let onCutEntries: ([RemoteFileEntry]) -> Void
    private let canPasteIntoDirectory: (String) -> Bool
    private let onPasteIntoDirectory: (String) -> Void
    private let onCloneEntry: (RemoteFileEntry) -> Void
    private let onMoveEntries: ([RemoteFileEntry]) -> Void
    private let onCopyPath: (String) -> Void
    private let onUploadToDirectory: (String) -> Void
    private let onUploadLocalFiles: ([URL], String) -> Void
    var onEditPermissions: ((RemoteFileEntry) -> Void)?
    var onShowProperties: ((RemoteFileEntry) -> Void)?
    var onOpenTextFile: ((RemoteFileEntry) -> Void)?
    var onOpenLogView: ((RemoteFileEntry) -> Void)?
    var onCompressEntries: (([RemoteFileEntry], ArchiveFormat) -> Void)?
    var onExtractEntry: ((RemoteFileEntry, FileManagerWindowSplitController.ExtractDestinationAction) -> Void)?

    private let tableView = FileManagerDetailTableView()
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
        onDownloadEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCutEntries: @escaping ([RemoteFileEntry]) -> Void,
        canPasteIntoDirectory: @escaping (String) -> Bool,
        onPasteIntoDirectory: @escaping (String) -> Void,
        onCloneEntry: @escaping (RemoteFileEntry) -> Void,
        onMoveEntries: @escaping ([RemoteFileEntry]) -> Void,
        onCopyPath: @escaping (String) -> Void,
        onUploadToDirectory: @escaping (String) -> Void,
        onUploadLocalFiles: @escaping ([URL], String) -> Void
    ) {
        self.onOpenDirectory = onOpenDirectory
        self.onRefresh = onRefresh
        self.onAddCurrentQuickPath = onAddCurrentQuickPath
        self.onCreateDirectory = onCreateDirectory
        self.onCreateFile = onCreateFile
        self.onRenameEntry = onRenameEntry
        self.onDeleteEntries = onDeleteEntries
        self.onDownloadEntries = onDownloadEntries
        self.onCopyEntries = onCopyEntries
        self.onCutEntries = onCutEntries
        self.canPasteIntoDirectory = canPasteIntoDirectory
        self.onPasteIntoDirectory = onPasteIntoDirectory
        self.onCloneEntry = onCloneEntry
        self.onMoveEntries = onMoveEntries
        self.onCopyPath = onCopyPath
        self.onUploadToDirectory = onUploadToDirectory
        self.onUploadLocalFiles = onUploadLocalFiles
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = FileManagerDetailDropContainerView()
        LogManager.debug(.fileManager, "detail viewDidLoad")

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
        tableView.onFileDrop = { [weak self] urls in
            guard let self else { return false }
            let accepted = RemoteDropRouting.acceptedLocalDropURLs(urls)
            guard !accepted.isEmpty else { return false }
            LogManager.debug(.fileManager, "detail performFileDrop count=\(accepted.count) path=\(self.currentPath)")
            self.onUploadLocalFiles(accepted, self.currentPath)
            return true
        }

        scrollView = FileManagerDetailDropScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        container.onFileDrop = { [weak self] urls in
            guard let self else { return false }
            let accepted = RemoteDropRouting.acceptedLocalDropURLs(urls)
            guard !accepted.isEmpty else { return false }
            LogManager.debug(.fileManager, "detail container performFileDrop count=\(accepted.count) path=\(self.currentPath)")
            self.onUploadLocalFiles(accepted, self.currentPath)
            return true
        }
        if let dropScrollView = scrollView as? FileManagerDetailDropScrollView {
            dropScrollView.onFileDrop = { [weak self] urls in
                guard let self else { return false }
                let accepted = RemoteDropRouting.acceptedLocalDropURLs(urls)
                guard !accepted.isEmpty else { return false }
                LogManager.debug(.fileManager, "detail scrollView performFileDrop count=\(accepted.count) path=\(self.currentPath)")
                self.onUploadLocalFiles(accepted, self.currentPath)
                return true
            }
        }

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
        searchQuery: String,
        transferProgress: Double? = nil
    ) {
        LogManager.debug(
            .fileManager,
            "detail update path=\(currentPath) entries=\(entries.count) loading=\(isLoading) search=\(searchQuery)"
        )
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
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            result.imageView = imageView
            result.addSubview(imageView)
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            result.textField = textField
            result.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 8),
                imageView.centerYAnchor.constraint(equalTo: result.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            ])
            return result
        }()

        cell.textField?.font = column == .name ? .systemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 12)
        cell.textField?.stringValue = value(for: entry, column: column)
        cell.textField?.textColor = .labelColor
        if column == .name {
            cell.imageView?.image = icon(for: entry)
            cell.imageView?.isHidden = false
        } else {
            cell.imageView?.image = nil
            cell.imageView?.isHidden = true
        }
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
        LogManager.debug(.fileManager, "detail doubleClick row=\(row) path=\(entry.path) isDirectory=\(entry.isDirectory)")
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

    private func clickedEntry() -> RemoteFileEntry? {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < filteredEntries.count else { return nil }
        return filteredEntries[clickedRow]
    }

    private func copyPathTarget() -> String {
        FileManagerContextCopyPathResolver.detailTargetPath(
            currentPath: currentPath,
            clickedEntryPath: clickedEntry()?.path
        )
    }

    private func pasteTargetDirectory() -> String {
        FileManagerPasteTargetResolver.targetDirectory(
            currentPath: currentPath,
            clickedEntry: clickedEntry()
        )
    }

    private func buildContextMenu() -> NSMenu {
        let menu = FileManagerContextMenuBuilder.menu()
        menu.delegate = self
        return menu
    }

    @objc private func handleRefresh() {
        LogManager.debug(.fileManager, "detail context refresh path=\(currentPath)")
        onRefresh()
    }

    @objc private func handleCreateDirectory() {
        LogManager.debug(.fileManager, "detail context createDirectory path=\(currentPath)")
        onCreateDirectory(currentPath)
    }

    @objc private func handleCreateFile() {
        LogManager.debug(.fileManager, "detail context createFile path=\(currentPath)")
        onCreateFile(currentPath)
    }

    @objc private func handleAddCurrentQuickPath() {
        let targetPath: String
        if let entry = clickedOrSelectedEntries().first, entry.isDirectory {
            targetPath = entry.path
        } else {
            targetPath = currentPath
        }
        LogManager.debug(.fileManager, "detail context addQuickPath path=\(targetPath)")
        onAddCurrentQuickPath(targetPath)
    }

    @objc private func handleRemoveQuickPath() {
    }

    @objc private func handleUpload() {
        LogManager.debug(.fileManager, "detail context upload path=\(currentPath)")
        onUploadToDirectory(currentPath)
    }

    @objc private func handleRename() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        LogManager.debug(.fileManager, "detail context rename path=\(entry.path)")
        onRenameEntry(entry)
    }

    @objc private func handleDelete() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        LogManager.debug(.fileManager, "detail context delete count=\(entries.count)")
        onDeleteEntries(entries)
    }

    @objc private func handleCopyPath() {
        let targetPath = copyPathTarget()
        LogManager.debug(.fileManager, "detail context copyPath path=\(targetPath)")
        onCopyPath(targetPath)
    }

    @objc private func handleDownload() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        LogManager.debug(.fileManager, "detail context download count=\(entries.count)")
        animateDownload()
        onDownloadEntries(entries)
    }

    @objc private func handleCopyEntries() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        onCopyEntries(entries)
    }

    @objc private func handleCutEntries() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        onCutEntries(entries)
    }

    @objc private func handlePasteEntries() {
        onPasteIntoDirectory(pasteTargetDirectory())
    }

    @objc private func handleCloneEntry() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        onCloneEntry(entry)
    }

    @objc private func handleMoveEntries() {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        onMoveEntries(entries)
    }

    @objc private func handleCompressTarGz() {
        handleCompress(format: .tarGz)
    }

    @objc private func handleCompressTar() {
        handleCompress(format: .tar)
    }

    @objc private func handleCompressZip() {
        handleCompress(format: .zip)
    }

    @objc private func handleCompressSevenZip() {
        handleCompress(format: .sevenZip)
    }

    private func handleCompress(format: ArchiveFormat) {
        let entries = clickedOrSelectedEntries()
        guard !entries.isEmpty else { return }
        onCompressEntries?(entries, format)
    }

    @objc private func handleExtractToCurrentDirectory() {
        handleExtract(action: .currentDirectory)
    }

    @objc private func handleExtractToSameNameDirectory() {
        handleExtract(action: .sameNameDirectory)
    }

    @objc private func handleExtractToCustomDirectory() {
        handleExtract(action: .customDirectory)
    }

    private func handleExtract(action: FileManagerWindowSplitController.ExtractDestinationAction) {
        guard let entry = clickedOrSelectedEntries().first else { return }
        onExtractEntry?(entry, action)
    }

    @objc private func handleOpenTextFile() {
        guard let entry = clickedOrSelectedEntries().first, !entry.isDirectory else { return }
        LogManager.debug(.fileManager, "detail context openText path=\(entry.path)")
        onOpenTextFile?(entry)
    }

    @objc private func handleOpenLogView() {
        guard let entry = clickedOrSelectedEntries().first, !entry.isDirectory else { return }
        LogManager.debug(.fileManager, "detail context openLog path=\(entry.path)")
        onOpenLogView?(entry)
    }

    @objc private func handleShowProperties() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        LogManager.debug(.fileManager, "detail context properties path=\(entry.path)")
        onShowProperties?(entry)
    }

    @objc private func handleEditPermissions() {
        guard let entry = clickedOrSelectedEntries().first else { return }
        LogManager.debug(.fileManager, "detail context permissions path=\(entry.path)")
        onEditPermissions?(entry)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = tableView.clickedRow
        if clickedRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let selectedEntries = clickedOrSelectedEntries()
        let hasSelection = !selectedEntries.isEmpty
        let selectedFileCount = selectedEntries.filter { !$0.isDirectory }.count
        let canExtract = selectedEntries.count == 1
            && selectedEntries[0].isDirectory == false
            && ArchiveFormat.extractFormat(for: selectedEntries[0].path) != nil
        FileManagerContextMenuBuilder.update(
            menu,
            capabilities: FileManagerContextMenuBuilder.Capabilities(
                canModifySelection: hasSelection,
                canUseSelection: hasSelection,
                canArchiveSelection: hasSelection,
                canPaste: canPasteIntoDirectory(currentPath),
                canExtract: canExtract,
                canOpenFile: selectedEntries.count == 1 && selectedFileCount == 1,
                canShowInfo: hasSelection,
                canRemoveQuickPath: false
            )
        )
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

    private func icon(for entry: RemoteFileEntry) -> NSImage {
        let image: NSImage
        if entry.isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if let contentType = UTType(filenameExtension: (entry.name as NSString).pathExtension) {
            image = NSWorkspace.shared.icon(for: contentType)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func animateDownload() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 else { return }
        let columnIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
        guard columnIndex >= 0 else { return }
        guard let startRect = CrossWindowFlyAnimator.screenRect(
            for: tableView.frameOfCell(atColumn: columnIndex, row: row),
            in: tableView
        ) else {
            return
        }

        let targetView = ViewScreenAnchorRegistry.view(for: ViewScreenAnchorRegistry.transferQueueTarget)
        let fallbackPoint = (targetView?.window ?? tableView.window).map {
            CGPoint(x: $0.frame.maxX - 28, y: $0.frame.minY + 28)
        }
        let image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: tr("Download File")
        ) ?? NSImage()

        if let targetView {
            CrossWindowFlyAnimator.animate(
                image: image,
                fromScreenRect: startRect,
                toScreenRect: CrossWindowFlyAnimator.screenRect(for: targetView) ?? CGRect(origin: fallbackPoint ?? .zero, size: .zero)
            )
        } else if let fallbackPoint {
            CrossWindowFlyAnimator.animate(
                image: image,
                fromScreenRect: startRect,
                toScreenRect: CGRect(origin: fallbackPoint, size: .zero)
            )
        }
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

@MainActor
private final class FileManagerDetailDropContainerView: NSView {
    var onFileDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail container draggingEntered count=\(urls.count)")
        return urls.isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail container prepareForDragOperation count=\(urls.count)")
        return !urls.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail container performDragOperation count=\(urls.count)")
        guard !urls.isEmpty else { return false }
        return onFileDrop?(urls) ?? false
    }
}

@MainActor
private final class FileManagerDetailDropScrollView: NSScrollView {
    var onFileDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail scrollView draggingEntered count=\(urls.count)")
        return urls.isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail scrollView prepareForDragOperation count=\(urls.count)")
        return !urls.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail scrollView performDragOperation count=\(urls.count)")
        guard !urls.isEmpty else { return false }
        return onFileDrop?(urls) ?? false
    }
}

@MainActor
private final class FileManagerDetailTableView: NSTableView {
    var onFileDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail tableView draggingEntered count=\(urls.count)")
        return urls.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail tableView draggingUpdated count=\(urls.count)")
        return urls.isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail tableView prepareForDragOperation count=\(urls.count)")
        return !urls.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        LogManager.debug(.fileManager, "detail tableView performDragOperation count=\(urls.count)")
        guard !urls.isEmpty else { return false }
        return onFileDrop?(urls) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        LogManager.debug(.fileManager, "detail tableView concludeDragOperation")
        super.concludeDragOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        LogManager.debug(.fileManager, "detail tableView draggingExited")
        super.draggingExited(sender)
    }
}

@MainActor
private func draggedFileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
    let pasteboard = draggingInfo.draggingPasteboard
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    return RemoteDropRouting.acceptedLocalDropURLs(urls)
}
