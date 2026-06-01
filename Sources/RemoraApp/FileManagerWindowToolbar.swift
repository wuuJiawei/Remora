import AppKit

@MainActor
final class FileManagerWindowToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    let toolbar = NSToolbar(identifier: "file-manager-window-toolbar")
    let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 0))
    let pathControl = NSPathControl(frame: NSRect(x: 0, y: 0, width: 420, height: 28))

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onPathSelected: ((String) -> Void)?
    var onSearchChanged: ((String) -> Void)?

    private weak var backItem: NSToolbarItem?
    private weak var forwardItem: NSToolbarItem?
    private var pathMap: [String: String] = [:]

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifier = .fileManagerPathControl

        searchField.placeholderString = tr("Search")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self

        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(handlePathClick)
    }

    func update(currentPath: String, canGoBack: Bool, canGoForward: Bool) {
        backItem?.isEnabled = canGoBack
        forwardItem?.isEnabled = canGoForward
        pathControl.url = URL(fileURLWithPath: currentPath)
        pathMap = breadcrumbPathMap(for: currentPath)
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .fileManagerBack,
            .fileManagerForward,
            .fileManagerRefresh,
            .fileManagerPathControl,
            .flexibleSpace,
            .fileManagerSearch,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .fileManagerBack:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Back")
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(handleBack)
            backItem = item
            return item
        case .fileManagerForward:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Forward")
            item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(handleForward)
            forwardItem = item
            return item
        case .fileManagerRefresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Refresh")
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(handleRefresh)
            return item
        case .fileManagerPathControl:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Path")
            item.view = pathControl
            return item
        case .fileManagerSearch:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Search")
            item.view = searchField
            return item
        default:
            return nil
        }
    }

    @objc private func handleBack() { onBack?() }
    @objc private func handleForward() { onForward?() }
    @objc private func handleRefresh() { onRefresh?() }

    @objc private func handlePathClick() {
        guard let clicked = pathControl.clickedPathItem else { return }
        if let mapped = pathMap[clicked.title] {
            onPathSelected?(mapped)
        }
    }

    private func breadcrumbPathMap(for currentPath: String) -> [String: String] {
        let normalized = currentPath.isEmpty ? "/" : currentPath
        let components = normalized.split(separator: "/").map(String.init)
        if components.isEmpty {
            return [tr("Root"): "/"]
        }

        var map: [String: String] = [tr("Root"): "/"]
        var current = ""
        for component in components {
            current += "/\(component)"
            map[component] = current
        }
        return map
    }
}

private extension NSToolbarItem.Identifier {
    static let fileManagerBack = NSToolbarItem.Identifier("file-manager-toolbar-back")
    static let fileManagerForward = NSToolbarItem.Identifier("file-manager-toolbar-forward")
    static let fileManagerRefresh = NSToolbarItem.Identifier("file-manager-toolbar-refresh")
    static let fileManagerPathControl = NSToolbarItem.Identifier("file-manager-toolbar-path")
    static let fileManagerSearch = NSToolbarItem.Identifier("file-manager-toolbar-search")
}
