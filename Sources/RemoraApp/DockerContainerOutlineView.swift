import AppKit

@MainActor
final class DockerContainerOutlineView: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelectionChanged: ((DockerResourceSelection?) -> Void)?

    private let listViewModel: DockerContainerListViewModel
    private let outlineView = DockerContainerListOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private var scrollView: NSScrollView!
    private var nodes: [DockerContainerNode] = []
    private var nodeByID: [String: DockerContainerNode] = [:]
    private var expandedIDs: Set<String> = []
    private var selectedID: String?
    private let fallbackNode = DockerContainerNode.section(id: "fallback", title: "", children: [])

    init(listViewModel: DockerContainerListViewModel) {
        self.listViewModel = listViewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        let column = NSTableColumn(identifier: .init("container-outline"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.intercellSpacing = NSSize(width: 0, height: 4)
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 14
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.menu = buildContextMenu()
        outlineView.backgroundColor = .clear

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(
            top: DockerListMetrics.contentTopPadding,
            left: 0,
            bottom: DockerListMetrics.contentBottomPadding,
            right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: 0,
            right: DockerListMetrics.scrollerRightInset
        )

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
        view = container
    }

    func reload(
        nodes: [DockerContainerNode],
        isLoading: Bool,
        emptyMessage: String
    ) {
        guard isViewLoaded else { return }
        selectedID = selectedNode?.id ?? selectedID
        expandedIDs.formUnion(nodes.map(\.id))
        self.nodes = nodes
        nodeByID = Dictionary(uniqueKeysWithValues: nodes.flatMap(flatten).map { ($0.id, $0) })
        outlineView.reloadData()
        restoreExpansion()
        restoreSelection()
        updateEmptyState(isLoading: isLoading, emptyMessage: emptyMessage)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return nodes.count
        }
        guard let node = item as? DockerContainerNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            guard nodes.indices.contains(index) else { return fallbackNode }
            return nodes[index]
        }
        guard let node = item as? DockerContainerNode,
              node.children.indices.contains(index)
        else { return fallbackNode }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? DockerContainerNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? DockerContainerNode else { return false }
        return node.kind != .section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let node = item as? DockerContainerNode else { return false }
        return node.kind == .compose
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? DockerContainerNode else { return false }
        return node.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? DockerContainerNode else { return 56 }
        switch node.kind {
        case .section:
            return DockerListMetrics.sectionHeaderHeight
        case .compose:
            return DockerListMetrics.composeRowHeight
        case .container:
            return DockerListMetrics.rowHeight
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? DockerContainerNode, node.kind != .section else {
            return DockerContainerListRowView()
        }
        return DockerContainerListRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DockerContainerNode else { return nil }
        switch node.kind {
        case .section:
            let identifier = NSUserInterfaceItemIdentifier("docker-section-header")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? DockerSectionHeaderView ?? DockerSectionHeaderView()
            view.identifier = identifier
            view.configure(title: node.title)
            return view
        case .compose:
            let identifier = NSUserInterfaceItemIdentifier("docker-compose-row")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? DockerComposeRowView ?? DockerComposeRowView()
            view.identifier = identifier
            view.configure(node: node)
            if let project = node.composeProject {
                view.onStart = { [weak self] in self?.listViewModel.startCompose(project) }
                view.onStop = { [weak self] in self?.listViewModel.stopCompose(project) }
                view.onDelete = { [weak self] in self?.listViewModel.removeCompose(project) }
            }
            return view
        case .container:
            guard let container = node.container else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("docker-container-row")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? DockerContainerRowView ?? DockerContainerRowView()
            view.identifier = identifier
            let parent = outlineView.parent(forItem: node) as? DockerContainerNode
            view.configure(container: container, isChild: parent?.kind == .compose)
            view.onStart = { [weak self] in self?.listViewModel.startContainer(container) }
            view.onStop = { [weak self] in self?.listViewModel.stopContainer(container) }
            view.onDelete = { [weak self] in self?.listViewModel.removeContainer(container) }
            view.onLogs = { [weak self] in self?.listViewModel.openContainerLogs(container) }
            view.onShell = { [weak self] in self?.listViewModel.openContainerShell(container) }
            return view
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = selectedNode else {
            selectedID = nil
            onSelectionChanged?(nil)
            return
        }
        selectedID = node.id
        onSelectionChanged?(selection(for: node))
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DockerContainerNode else { return }
        expandedIDs.insert(node.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DockerContainerNode else { return }
        expandedIDs.remove(node.id)
    }

    @objc private func handleDoubleClick() {
        guard let node = selectedNode else { return }
        if node.kind == .compose {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else if let container = node.container, container.isRunning {
            listViewModel.openContainerShell(container)
        }
    }

    private func restoreExpansion() {
        for node in nodeByID.values where !node.children.isEmpty {
            if node.kind == .section || expandedIDs.contains(node.id) {
                outlineView.expandItem(node)
            }
        }
    }

    private func restoreSelection() {
        guard let selectedID,
              let node = nodeByID[selectedID]
        else {
            if let first = firstSelectableNode(in: nodes) {
                let row = outlineView.row(forItem: first)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else {
                outlineView.deselectAll(nil)
                onSelectionChanged?(nil)
            }
            return
        }
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func updateEmptyState(isLoading: Bool, emptyMessage: String) {
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        emptyLabel.stringValue = nodes.isEmpty ? emptyMessage : ""
        emptyLabel.isHidden = !nodes.isEmpty
        loadingIndicator.isHidden = !nodes.isEmpty || !isLoading
    }

    private var selectedNode: DockerContainerNode? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? DockerContainerNode
    }

    private func selection(for node: DockerContainerNode) -> DockerResourceSelection? {
        switch node.kind {
        case .section:
            return nil
        case .compose:
            return node.composeProject.map(DockerResourceSelection.compose)
        case .container:
            return node.container.map(DockerResourceSelection.container)
        }
    }

    private func flatten(_ node: DockerContainerNode) -> [DockerContainerNode] {
        [node] + node.children.flatMap(flatten)
    }

    private func firstSelectableNode(in nodes: [DockerContainerNode]) -> DockerContainerNode? {
        for node in nodes {
            if node.kind != .section {
                return node
            }
            if let child = firstSelectableNode(in: node.children) {
                return child
            }
        }
        return nil
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = selectedNode else { return }
        if let container = node.container {
            addContainerMenu(container, to: menu)
        } else if let project = node.composeProject {
            addComposeMenu(project, to: menu)
        }
    }

    private func addContainerMenu(_ container: DockerContainer, to menu: NSMenu) {
        if container.isRunning {
            menu.addItem(actionItem(tr("Stop")) { [weak self] in self?.listViewModel.stopContainer(container) })
            menu.addItem(actionItem(tr("Restart")) { [weak self] in self?.listViewModel.restartContainer(container) })
            menu.addItem(actionItem(tr("Kill")) { [weak self] in self?.listViewModel.killContainer(container) })
            menu.addItem(actionItem(tr("Pause")) { [weak self] in self?.listViewModel.pauseContainer(container) })
        } else {
            menu.addItem(actionItem(tr("Start")) { [weak self] in self?.listViewModel.startContainer(container) })
        }
        menu.addItem(actionItem(tr("Delete")) { [weak self] in self?.listViewModel.removeContainer(container) })
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Logs")) { [weak self] in self?.listViewModel.openContainerLogs(container) })
        menu.addItem(actionItem(tr("Terminal"), enabled: container.isRunning) { [weak self] in self?.listViewModel.openContainerShell(container) })
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Copy ID")) { [weak self] in self?.listViewModel.copy(container.id) })
        menu.addItem(actionItem(tr("Copy Name")) { [weak self] in self?.listViewModel.copy(container.name) })
        menu.addItem(actionItem(tr("Copy Image")) { [weak self] in self?.listViewModel.copy(container.image) })
    }

    private func addComposeMenu(_ project: DockerComposeProject, to menu: NSMenu) {
        menu.addItem(actionItem(tr("Start"), enabled: project.canRunCommands) { [weak self] in self?.listViewModel.startCompose(project) })
        menu.addItem(actionItem(tr("Stop"), enabled: project.canRunCommands) { [weak self] in self?.listViewModel.stopCompose(project) })
        menu.addItem(actionItem(tr("Restart"), enabled: project.canRunCommands) { [weak self] in self?.listViewModel.restartCompose(project) })
        menu.addItem(actionItem(tr("Pause"), enabled: project.canRunCommands) { [weak self] in self?.listViewModel.pauseCompose(project) })
        menu.addItem(actionItem(tr("Kill"), enabled: project.canRunCommands) { [weak self] in self?.listViewModel.killCompose(project) })
        menu.addItem(actionItem(tr("Delete"), enabled: project.canRunCommands) { [weak self] in self?.listViewModel.removeCompose(project) })
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Logs"), enabled: project.canRunCommands) { [weak self] in self?.listViewModel.openComposeLogs(project) })
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Copy Name")) { [weak self] in self?.listViewModel.copy(project.name) })
        if let workingDir = project.workingDir {
            menu.addItem(actionItem(tr("Copy Path")) { [weak self] in self?.listViewModel.copy(workingDir) })
        }
    }

    private func actionItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = DockerClosureMenuItem(title: title, actionHandler: action)
        item.isEnabled = enabled
        return item
    }
}

private final class DockerClosureMenuItem: NSMenuItem {
    private let actionHandler: () -> Void

    init(title: String, actionHandler: @escaping () -> Void) {
        self.actionHandler = actionHandler
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        actionHandler()
    }
}

private final class DockerContainerListOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard row >= 0,
              let node = item(atRow: row) as? DockerContainerNode,
              node.kind == .compose
        else {
            return frame
        }

        let cellFrame = super.frameOfCell(atColumn: 0, row: row)
        guard cellFrame.width > 0, frame.width > 0 else { return frame }

        let iconX = cellFrame.minX + DockerListMetrics.primaryIconLeading
        frame.origin.x = max(0, iconX - DockerListMetrics.disclosureIconSpacing - frame.width)
        return frame
    }
}

private final class DockerContainerListRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(
            dx: DockerListMetrics.contentHorizontalPadding * 0.5,
            dy: 4
        )
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: DockerListMetrics.rowCornerRadius,
            yRadius: DockerListMetrics.rowCornerRadius
        )
        NSColor.controlAccentColor.setFill()
        path.fill()
    }
}
