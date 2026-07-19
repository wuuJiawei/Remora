import AppKit
import SwiftUI

@MainActor
final class FileManagerWindowToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    let toolbar = NSToolbar(identifier: "file-manager-window-toolbar")
    let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
    let pathControl = FileManagerToolbarPathControl(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
    fileprivate let downloadsButtonView = FileManagerDownloadsButtonView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onPathSelected: ((String) -> Void)?
    var onCopyCurrentPath: ((String) -> Void)?
    var onTerminalSyncToggled: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onDownloadsClicked: (() -> Void)?
    var downloadsAnchorView: NSView { downloadsButtonView }

    private weak var backItem: NSToolbarItem?
    private weak var forwardItem: NSToolbarItem?
    private weak var terminalSyncItem: NSToolbarItem?
    private var isTerminalSyncEnabled = false
    private var pathMap: [String: String] = [:]
    private var currentPathForCopy: String?

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
        pathControl.onCopyPath = { [weak self] in
            guard let self, let path = self.currentPathForCopy else { return }
            self.onCopyCurrentPath?(path)
        }

        downloadsButtonView.onClick = { [weak self] in
            self?.onDownloadsClicked?()
        }
    }

    func update(currentPath: String, canGoBack: Bool, canGoForward: Bool) {
        backItem?.isEnabled = canGoBack
        forwardItem?.isEnabled = canGoForward
        pathControl.url = URL(fileURLWithPath: currentPath)
        pathMap = breadcrumbPathMap(for: currentPath)
        currentPathForCopy = currentPath
    }

    func updateDownloads(progress: Double?, hasHistory: Bool, status: TransferQueueAggregateStatus) {
        downloadsButtonView.progress = progress
        downloadsButtonView.hasHistory = hasHistory
        downloadsButtonView.status = status
    }

    func updateTerminalSync(isEnabled: Bool) {
        isTerminalSyncEnabled = isEnabled
        terminalSyncItem?.image = NSImage(
            systemSymbolName: isEnabled ? "link.circle.fill" : "link",
            accessibilityDescription: tr("Terminal Sync")
        )
        terminalSyncItem?.toolTip = tr(isEnabled ? "Disable terminal sync" : "Enable terminal sync")
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
            .fileManagerDownloads,
            .fileManagerTerminalSync,
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
        case .fileManagerDownloads:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Transfers")
            item.view = downloadsButtonView
            return item
        case .fileManagerTerminalSync:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Terminal Sync")
            item.image = NSImage(
                systemSymbolName: isTerminalSyncEnabled ? "link.circle.fill" : "link",
                accessibilityDescription: item.label
            )
            item.toolTip = tr(isTerminalSyncEnabled ? "Disable terminal sync" : "Enable terminal sync")
            item.target = self
            item.action = #selector(handleTerminalSyncToggle)
            terminalSyncItem = item
            return item
        default:
            return nil
        }
    }

    @objc private func handleBack() { onBack?() }
    @objc private func handleForward() { onForward?() }
    @objc private func handleRefresh() { onRefresh?() }
    @objc private func handleTerminalSyncToggle() { onTerminalSyncToggled?() }

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

@MainActor
final class FileManagerToolbarPathControl: NSPathControl {
    var onCopyPath: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: tr("Copy Path"), action: #selector(handleCopyPath), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func handleCopyPath() {
        onCopyPath?()
    }
}

private extension NSToolbarItem.Identifier {
    static let fileManagerBack = NSToolbarItem.Identifier("file-manager-toolbar-back")
    static let fileManagerForward = NSToolbarItem.Identifier("file-manager-toolbar-forward")
    static let fileManagerRefresh = NSToolbarItem.Identifier("file-manager-toolbar-refresh")
    static let fileManagerPathControl = NSToolbarItem.Identifier("file-manager-toolbar-path")
    static let fileManagerDownloads = NSToolbarItem.Identifier("file-manager-toolbar-downloads")
    static let fileManagerTerminalSync = NSToolbarItem.Identifier("file-manager-toolbar-terminal-sync")
    static let fileManagerSearch = NSToolbarItem.Identifier("file-manager-toolbar-search")
}

@MainActor
private final class FileManagerDownloadsButtonView: NSView {
    var onClick: (() -> Void)?
    var progress: Double? {
        didSet { needsDisplay = true }
    }
    var hasHistory = false {
        didSet {
            button.isEnabled = hasHistory || progress != nil
            updateAppearance()
            needsDisplay = true
        }
    }
    var status: TransferQueueAggregateStatus = .idle {
        didSet {
            updateAppearance()
            needsDisplay = true
        }
    }

    private let button: NSButton = {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: tr("Transfers"))
        button.contentTintColor = .labelColor
        button.bezelStyle = .texturedRounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        button.target = self
        button.action = #selector(handleClick)
        button.isEnabled = false
        wantsLayer = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let progress else { return }
        let clamped = min(max(progress, 0), 1)
        let ringRect = bounds.insetBy(dx: 2, dy: 2)
        let backgroundPath = NSBezierPath(ovalIn: ringRect)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        backgroundPath.lineWidth = 2
        backgroundPath.stroke()

        let startAngle: CGFloat = 90
        let endAngle = startAngle - (360 * clamped)
        let progressPath = NSBezierPath()
        progressPath.appendArc(
            withCenter: CGPoint(x: ringRect.midX, y: ringRect.midY),
            radius: min(ringRect.width, ringRect.height) / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        NSColor.controlAccentColor.setStroke()
        progressPath.lineWidth = 2.4
        progressPath.lineCapStyle = .round
        progressPath.stroke()
    }

    @objc private func handleClick() {
        onClick?()
    }

    private func updateAppearance() {
        let symbolName: String
        let tintColor: NSColor

        switch status {
        case .idle:
            symbolName = "arrow.left.arrow.right"
            tintColor = hasHistory ? .secondaryLabelColor : .labelColor
        case .transferring:
            symbolName = "arrow.left.arrow.right"
            tintColor = .controlAccentColor
        case .completed:
            symbolName = "checkmark.circle.fill"
            tintColor = .systemGreen
        case .finishedWithIssues:
            symbolName = "exclamationmark.circle.fill"
            tintColor = .systemOrange
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tr("Transfers"))
        button.contentTintColor = tintColor
    }
}
