import AppKit
import Combine

@MainActor
final class DockerWindowSplitController: NSSplitViewController {
    private let viewModel: DockerPanelViewModel
    private let sidebarController: DockerOutlineSidebarController
    private let listController: DockerResourceListContainerController
    private let detailController: DockerResourceDetailController
    private var cancellables: Set<AnyCancellable> = []

    init(
        viewModel: DockerPanelViewModel,
        onOpenContainerShell: @escaping (DockerContainer) -> Void
    ) {
        self.viewModel = viewModel
        self.sidebarController = DockerOutlineSidebarController(viewModel: viewModel)
        self.listController = DockerResourceListContainerController(
            viewModel: viewModel,
            onOpenContainerShell: onOpenContainerShell
        )
        self.detailController = DockerResourceDetailController(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)

        listController.onSelectionChanged = { [weak detailController] selection in
            detailController?.selection = selection
        }
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
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = true

        let tableItem = NSSplitViewItem(viewController: listController)
        tableItem.minimumThickness = DockerListMetrics.minContainerListWidth

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = DockerListMetrics.minDetailWidth
        detailItem.maximumThickness = 420
        detailItem.canCollapse = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(tableItem)
        addSplitViewItem(detailItem)

        bindViewModel()
        reloadAll()
    }

    func applyToolbarSearch(_ query: String) {
        switch viewModel.selectedTab {
        case .containers:
            viewModel.containerFilterText = query
            viewModel.composeFilterText = query
        case .volumes:
            viewModel.volumeFilterText = query
        case .images:
            viewModel.imageFilterText = query
        case .networks:
            viewModel.networkFilterText = query
        case .kubernetesPods, .kubernetesServices, .machines, .activityMonitor, .commands:
            break
        }
    }

    private func bindViewModel() {
        let publishers: [AnyPublisher<Void, Never>] = [
            viewModel.$selectedTab.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$runtimeBinding.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$environment.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$containers.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$volumes.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$images.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$networks.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$composeProjects.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$activitySnapshot.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$activitySortDescriptor.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$containerDetails.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isLoadingContainers.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isLoadingVolumes.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isLoadingImages.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isLoadingNetworks.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isLoadingActivity.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$containerFilterText.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$volumeFilterText.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$imageFilterText.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$networkFilterText.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$composeFilterText.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(publishers)
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: Void) in
                self?.reloadAll()
            }
            .store(in: &cancellables)
    }

    private func reloadAll() {
        sidebarController.reload()
        listController.reload()
        detailController.reload()
    }
}

@MainActor
private final class DockerOutlineSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Section: String, CaseIterable {
        case docker
        case kubernetes
        case general

        var title: String {
            switch self {
            case .docker: return tr("Docker")
            case .kubernetes: return tr("Kubernetes")
            case .general: return tr("General")
            }
        }

        var children: [DockerPanelSelection] {
            switch self {
            case .docker:
                return [.containers, .volumes, .images, .networks]
            case .kubernetes:
                return [.kubernetesPods, .kubernetesServices]
            case .general:
                return [.activityMonitor]
            }
        }
    }

    private let viewModel: DockerPanelViewModel
    private let outlineView = NSOutlineView()
    private var scrollView: NSScrollView!
    private var isSelectingProgrammatically = false

    init(viewModel: DockerPanelViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("docker-sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.target = self
        outlineView.action = #selector(selectionDidChange)

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let container = NSView()
        container.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        Section.allCases.forEach { outlineView.expandItem($0) }
        syncSelection()
    }

    func reload() {
        guard isViewLoaded else { return }
        outlineView.reloadData()
        Section.allCases.forEach { outlineView.expandItem($0) }
        syncSelection()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return Section.allCases.count
        }
        if let section = item as? Section {
            return section.children.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return Section.allCases[index]
        }
        if let section = item as? Section {
            return section.children[index]
        }
        return Section.docker
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is DockerPanelSelection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        DockerSidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? Section {
            let identifier = NSUserInterfaceItemIdentifier("docker-sidebar-section")
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
            cell.textField?.stringValue = section.title
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }

        guard let selection = item as? DockerPanelSelection else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("docker-sidebar-item")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
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
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            ])
            return result
        }()
        cell.textField?.stringValue = selection.title
        cell.textField?.font = .systemFont(ofSize: 13)
        cell.textField?.textColor = .labelColor
        cell.imageView?.image = NSImage(systemSymbolName: selection.systemImage, accessibilityDescription: selection.title)
        cell.imageView?.contentTintColor = .secondaryLabelColor
        return cell
    }

    @objc private func selectionDidChange() {
        guard !isSelectingProgrammatically else { return }
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let selection = outlineView.item(atRow: selectedRow) as? DockerPanelSelection
        else { return }
        viewModel.selectedTab = selection
    }

    private func syncSelection() {
        isSelectingProgrammatically = true
        defer { isSelectingProgrammatically = false }

        let row = outlineView.row(forItem: viewModel.selectedTab)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }
}

private final class DockerSidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
}

@MainActor
private final class DockerResourceListContainerController: NSViewController {
    var onSelectionChanged: ((DockerResourceSelection?) -> Void)? {
        didSet {
            containerListController.onSelectionChanged = onSelectionChanged
            resourceTableController.onSelectionChanged = onSelectionChanged
        }
    }

    private let viewModel: DockerPanelViewModel
    private let containerListController: DockerContainerListView
    private let resourceTableController: DockerResourceTableController
    private let kubernetesComingSoonController = DockerComingSoonController()
    private var activeController: NSViewController?

    init(
        viewModel: DockerPanelViewModel,
        onOpenContainerShell: @escaping (DockerContainer) -> Void
    ) {
        self.viewModel = viewModel
        self.containerListController = DockerContainerListView(
            panelViewModel: viewModel,
            onOpenContainerShell: onOpenContainerShell
        )
        self.resourceTableController = DockerResourceTableController(
            viewModel: viewModel,
            onOpenContainerShell: onOpenContainerShell
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    func reload() {
        guard isViewLoaded else { return }
        let target: NSViewController = {
            if viewModel.selectedTab.isKubernetesPendingFeature {
                return kubernetesComingSoonController
            }
            if viewModel.selectedTab == .containers {
                return containerListController
            }
            return resourceTableController
        }()
        show(target)
        if viewModel.selectedTab == .containers {
            LogManager.debug(
                .docker,
                "containerList reload rawContainers=\(viewModel.containers.count) filteredContainers=\(viewModel.filteredContainers.count) rawCompose=\(viewModel.composeProjects.count) filteredCompose=\(viewModel.filteredComposeProjects.count) containerFilter=\(Self.logFilter(viewModel.containerFilterText)) composeFilter=\(Self.logFilter(viewModel.composeFilterText)) isLoadingContainers=\(viewModel.isLoadingContainers) isLoadingCompose=\(viewModel.isLoadingCompose)"
            )
            containerListController.reload(
                containers: viewModel.filteredContainers,
                composeProjects: viewModel.filteredComposeProjects,
                isLoading: viewModel.isLoadingContainers || viewModel.isLoadingCompose
            )
        } else if !viewModel.selectedTab.isKubernetesPendingFeature {
            resourceTableController.reload()
        }
    }

    private func show(_ controller: NSViewController) {
        guard activeController !== controller else { return }
        if let activeController {
            activeController.view.removeFromSuperview()
            activeController.removeFromParent()
        }
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        activeController = controller
        onSelectionChanged?(nil)
    }

    private static func logFilter(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }
}

@MainActor
private final class DockerResourceTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelectionChanged: ((DockerResourceSelection?) -> Void)?

    private let viewModel: DockerPanelViewModel
    private let onOpenContainerShell: (DockerContainer) -> Void
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private var scrollView: NSScrollView!
    private var rows: [DockerResourceRow] = []
    private var selectedID: String?
    private var isApplyingSortDescriptors = false

    init(
        viewModel: DockerPanelViewModel,
        onOpenContainerShell: @escaping (DockerContainer) -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenContainerShell = onOpenContainerShell
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.menu = buildContextMenu()

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

    func reload() {
        guard isViewLoaded else { return }
        selectedID = selectedRow?.id ?? selectedID
        rows = makeRows()
        rebuildColumns()
        updateSortDescriptors()
        tableView.reloadData()
        restoreSelection()
        synchronizeSelection()
        updateEmptyState()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return rows[row].isGroup
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return !rows[row].isGroup
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 30 }
        return rows[row].isGroup ? 26 : 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        guard let columnID = tableColumn?.identifier.rawValue else { return nil }

        if item.isGroup {
            let identifier = NSUserInterfaceItemIdentifier("docker-table-group")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? DockerCellFactory.makeTextCell(identifier: identifier, leading: 8)
            cell.textField?.stringValue = item.groupTitle ?? ""
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            cell.imageView?.isHidden = true
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("docker-table-\(columnID)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? DockerCellFactory.makeTextCell(identifier: identifier, leading: columnID == "name" ? 8 : 6)
        configure(cell: cell, row: item, columnID: columnID)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        synchronizeSelection()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSortDescriptors,
              viewModel.selectedTab == .activityMonitor,
              let descriptor = tableView.sortDescriptors.first,
              let columnID = descriptor.key
        else { return }
        viewModel.toggleActivitySort(columnID: columnID)
    }

    @objc private func handleDoubleClick() {
        guard let row = selectedRow else { return }
        if case .container(let container) = row.selection, container.isRunning {
            onOpenContainerShell(container)
        } else if case .compose(let project) = row.selection {
            viewModel.loadComposeLogs(project)
        }
    }

    private func rebuildColumns() {
        let columns = columnsForCurrentSelection()
        let existing = tableView.tableColumns.map(\.identifier.rawValue)
        guard existing != columns.map(\.id) else { return }

        tableView.deselectAll(nil)
        tableView.reloadData()
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        for column in columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.resizingMask = .userResizingMask
            if viewModel.selectedTab == .activityMonitor,
               ActivityMonitorSortField(columnID: column.id) != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            tableView.addTableColumn(tableColumn)
        }
    }

    private func updateSortDescriptors() {
        guard viewModel.selectedTab == .activityMonitor else {
            guard !tableView.sortDescriptors.isEmpty else { return }
            isApplyingSortDescriptors = true
            tableView.sortDescriptors = []
            isApplyingSortDescriptors = false
            return
        }

        let descriptor = viewModel.activitySortDescriptor
        isApplyingSortDescriptors = true
        tableView.sortDescriptors = [
            NSSortDescriptor(key: descriptor.field.rawValue, ascending: descriptor.ascending)
        ]
        isApplyingSortDescriptors = false
    }

    private func configure(cell: NSTableCellView, row: DockerResourceRow, columnID: String) {
        cell.textField?.font = columnID == "name" ? .systemFont(ofSize: 13) : .systemFont(ofSize: 12)
        cell.textField?.textColor = .labelColor
        cell.textField?.lineBreakMode = .byTruncatingMiddle
        cell.imageView?.isHidden = columnID != "name"
        cell.imageView?.image = columnID == "name" ? row.icon : nil
        cell.imageView?.contentTintColor = row.tint
        cell.textField?.stringValue = value(for: row, columnID: columnID)
    }

    private func value(for row: DockerResourceRow, columnID: String) -> String {
        switch row.selection {
        case .container(let container):
            switch columnID {
            case "name": return container.name
            case "image": return container.image
            case "status": return container.stateBadgeLabel
            case "ports": return container.ports ?? dash
            case "compose": return composeSummary(for: container)
            case "id": return container.shortID
            default: return dash
            }
        case .compose(let project):
            switch columnID {
            case "name": return project.name
            case "status": return project.status ?? dash
            case "services": return project.serviceCount.map(String.init) ?? dash
            case "workingDir": return project.workingDir ?? dash
            default: return dash
            }
        case .volume(let volume):
            switch columnID {
            case "name": return volume.name
            case "driver": return volume.driver ?? dash
            case "scope": return volume.scope ?? dash
            case "mountpoint": return volume.mountpoint ?? dash
            default: return dash
            }
        case .image(let image):
            switch columnID {
            case "name": return image.displayName
            case "id": return image.shortID
            case "created": return image.createdSince ?? image.createdAt ?? dash
            case "size": return image.size ?? dash
            default: return dash
            }
        case .network(let network):
            switch columnID {
            case "name": return network.name
            case "id": return network.shortID
            case "driver": return network.driver ?? dash
            case "scope": return network.scope ?? dash
            case "subnet": return network.subnet ?? dash
            default: return dash
            }
        case .activity(let stat):
            switch columnID {
            case "name": return stat.name
            case "cpu": return String(format: "%.1f", stat.cpuPercent)
            case "memory": return stat.memoryUsage
            case "network": return stat.networkIO
            case "disk": return stat.blockIO
            case "pids": return stat.pids ?? dash
            default: return dash
            }
        case .placeholder:
            return row.title
        }
    }

    private func makeRows() -> [DockerResourceRow] {
        switch viewModel.selectedTab {
        case .containers:
            return containerRows()
        case .volumes:
            return viewModel.filteredVolumes.map { .volume($0) }
        case .images:
            return viewModel.filteredImages.map { .image($0) }
        case .networks:
            return viewModel.filteredNetworks.map { .network($0) }
        case .activityMonitor:
            return viewModel.sortedActivityStats.map { .activity($0) }
        case .kubernetesPods:
            return [.placeholder(title: tr("Pods"), subtitle: tr("Unavailable"))]
        case .kubernetesServices:
            return [.placeholder(title: tr("Services"), subtitle: tr("Unavailable"))]
        case .commands:
            return [.placeholder(title: tr("Commands"), subtitle: tr("Unavailable"))]
        case .machines:
            return [.placeholder(title: tr("Machines"), subtitle: tr("Unavailable"))]
        }
    }

    private func containerRows() -> [DockerResourceRow] {
        var result: [DockerResourceRow] = []
        let projectsByName = Dictionary(uniqueKeysWithValues: viewModel.filteredComposeProjects.map { ($0.name, $0) })
        appendContainerSection(title: tr("Running"), containers: viewModel.filteredContainers.filter(\.isRunning), projectsByName: projectsByName, rows: &result)
        appendContainerSection(title: tr("Stopped"), containers: viewModel.filteredContainers.filter { !$0.isRunning }, projectsByName: projectsByName, rows: &result)
        return result
    }

    private func appendContainerSection(
        title: String,
        containers: [DockerContainer],
        projectsByName: [String: DockerComposeProject],
        rows: inout [DockerResourceRow]
    ) {
        guard !containers.isEmpty else { return }
        rows.append(.group(title))

        let grouped = Dictionary(grouping: containers) { $0.composeProject ?? "" }
        let composeNames = grouped.keys.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in composeNames {
            let project = projectsByName[name] ?? DockerComposeProject(
                name: name,
                status: nil,
                configFiles: [],
                workingDir: nil,
                serviceCount: grouped[name]?.count
            )
            rows.append(.compose(project))
            for container in (grouped[name] ?? []).sorted(by: containerSort) {
                rows.append(.container(container))
            }
        }

        for container in (grouped[""] ?? []).sorted(by: containerSort) {
            rows.append(.container(container))
        }
    }

    private func columnsForCurrentSelection() -> [DockerTableColumnSpec] {
        switch viewModel.selectedTab {
        case .containers:
            return [
                .init(id: "name", title: tr("Name"), width: 220, minWidth: 160),
                .init(id: "image", title: tr("Image"), width: 220, minWidth: 140),
                .init(id: "status", title: tr("Status"), width: 130, minWidth: 90),
                .init(id: "ports", title: tr("Ports"), width: 160, minWidth: 100),
                .init(id: "compose", title: tr("Compose"), width: 140, minWidth: 90),
            ]
        case .volumes:
            return [
                .init(id: "name", title: tr("Name"), width: 240, minWidth: 160),
                .init(id: "driver", title: tr("Driver"), width: 120, minWidth: 80),
                .init(id: "scope", title: tr("Scope"), width: 100, minWidth: 80),
                .init(id: "mountpoint", title: tr("Mountpoint"), width: 320, minWidth: 160),
            ]
        case .images:
            return [
                .init(id: "name", title: tr("Name"), width: 280, minWidth: 180),
                .init(id: "id", title: tr("ID"), width: 150, minWidth: 100),
                .init(id: "created", title: tr("Created"), width: 150, minWidth: 100),
                .init(id: "size", title: tr("Size"), width: 100, minWidth: 80),
            ]
        case .networks:
            return [
                .init(id: "name", title: tr("Name"), width: 220, minWidth: 140),
                .init(id: "id", title: tr("ID"), width: 130, minWidth: 100),
                .init(id: "driver", title: tr("Driver"), width: 120, minWidth: 80),
                .init(id: "scope", title: tr("Scope"), width: 100, minWidth: 80),
                .init(id: "subnet", title: tr("Subnet"), width: 180, minWidth: 120),
            ]
        case .activityMonitor:
            return [
                .init(id: "name", title: tr("Name"), width: 220, minWidth: 150),
                .init(id: "cpu", title: tr("CPU %"), width: 80, minWidth: 70),
                .init(id: "memory", title: tr("Memory"), width: 130, minWidth: 90),
                .init(id: "network", title: tr("Network"), width: 130, minWidth: 90),
                .init(id: "disk", title: tr("Disk"), width: 130, minWidth: 90),
                .init(id: "pids", title: tr("PIDs"), width: 80, minWidth: 60),
            ]
        case .kubernetesPods, .kubernetesServices, .machines, .commands:
            return [
                .init(id: "name", title: tr("Name"), width: 260, minWidth: 160),
            ]
        }
    }

    private func restoreSelection() {
        guard let selectedID,
              let index = rows.firstIndex(where: { $0.id == selectedID && !$0.isGroup })
        else {
            if let first = rows.firstIndex(where: { !$0.isGroup }) {
                tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
                onSelectionChanged?(nil)
            }
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    private func synchronizeSelection() {
        guard let row = selectedRow else {
            selectedID = nil
            onSelectionChanged?(nil)
            return
        }
        selectedID = row.id
        if case .container(let container) = row.selection {
            viewModel.ensureContainerDetails(container)
        }
        onSelectionChanged?(row.selection)
    }

    private func updateEmptyState() {
        let isLoading = currentLoadingState
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        emptyLabel.stringValue = rows.isEmpty ? emptyMessage : ""
        emptyLabel.isHidden = !rows.isEmpty
        loadingIndicator.isHidden = !rows.isEmpty || !isLoading
    }

    private var currentLoadingState: Bool {
        switch viewModel.selectedTab {
        case .containers: return viewModel.isLoadingContainers || viewModel.isLoadingCompose
        case .volumes: return viewModel.isLoadingVolumes
        case .images: return viewModel.isLoadingImages
        case .networks: return viewModel.isLoadingNetworks
        case .activityMonitor: return viewModel.isLoadingActivity
        case .kubernetesPods, .kubernetesServices, .machines, .commands: return false
        }
    }

    private var emptyMessage: String {
        if currentLoadingState {
            return tr("Loading...")
        }
        switch viewModel.selectedTab {
        case .containers: return tr("No Docker containers were returned by the current server.")
        case .volumes: return tr("No volumes")
        case .images: return tr("No Docker images were returned by the current server.")
        case .networks: return tr("No networks")
        case .activityMonitor: return tr("No running containers")
        case .kubernetesPods, .kubernetesServices, .machines, .commands: return tr("Unavailable")
        }
    }

    private var selectedRow: DockerResourceRow? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = selectedRow else { return }
        switch row.selection {
        case .container(let container):
            addContainerMenu(container, to: menu)
        case .compose(let project):
            addComposeMenu(project, to: menu)
        case .volume(let volume):
            menu.addItem(actionItem(tr("Delete"), action: #selector(deleteVolume(_:)), representedObject: volume))
        case .image(let image):
            menu.addItem(actionItem(tr("Delete"), action: #selector(deleteImage(_:)), representedObject: image))
        case .network(let network):
            menu.addItem(actionItem(tr("Delete"), action: #selector(deleteNetwork(_:)), representedObject: network))
        case .activity(let stat):
            if let container = viewModel.containers.first(where: { $0.id == stat.containerID }) {
                addContainerMenu(container, to: menu)
            }
        case .placeholder:
            break
        }
    }

    private func addContainerMenu(_ container: DockerContainer, to menu: NSMenu) {
        if container.isRunning {
            menu.addItem(actionItem(tr("Stop"), action: #selector(stopContainer(_:)), representedObject: container))
            menu.addItem(actionItem(tr("Restart"), action: #selector(restartContainer(_:)), representedObject: container))
            menu.addItem(actionItem(tr("Kill"), action: #selector(killContainer(_:)), representedObject: container))
            menu.addItem(actionItem(tr("Pause"), action: #selector(pauseContainer(_:)), representedObject: container))
        } else {
            menu.addItem(actionItem(tr("Start"), action: #selector(startContainer(_:)), representedObject: container))
        }
        menu.addItem(actionItem(tr("Delete"), action: #selector(deleteContainer(_:)), representedObject: container))
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Logs"), action: #selector(containerLogs(_:)), representedObject: container))
        let terminalItem = actionItem(tr("Terminal"), action: #selector(openContainerShell(_:)), representedObject: container)
        terminalItem.isEnabled = container.isRunning
        menu.addItem(terminalItem)
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Copy ID"), action: #selector(copyRepresentedString(_:)), representedObject: container.id))
        menu.addItem(actionItem(tr("Copy Name"), action: #selector(copyRepresentedString(_:)), representedObject: container.name))
        menu.addItem(actionItem(tr("Copy Image"), action: #selector(copyRepresentedString(_:)), representedObject: container.image))
    }

    private func addComposeMenu(_ project: DockerComposeProject, to menu: NSMenu) {
        menu.addItem(actionItem(tr("Start"), action: #selector(composeUp(_:)), representedObject: project, enabled: project.canRunCommands))
        menu.addItem(actionItem(tr("Stop"), action: #selector(composeDown(_:)), representedObject: project, enabled: project.canRunCommands))
        menu.addItem(actionItem(tr("Restart"), action: #selector(composeRestart(_:)), representedObject: project, enabled: project.canRunCommands))
        menu.addItem(actionItem(tr("Pause"), action: #selector(composePause(_:)), representedObject: project, enabled: project.canRunCommands))
        menu.addItem(actionItem(tr("Kill"), action: #selector(composeKill(_:)), representedObject: project, enabled: project.canRunCommands))
        menu.addItem(actionItem(tr("Delete"), action: #selector(composeDown(_:)), representedObject: project, enabled: project.canRunCommands))
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Logs"), action: #selector(composeLogs(_:)), representedObject: project, enabled: project.canRunCommands))
        menu.addItem(.separator())
        menu.addItem(actionItem(tr("Copy Name"), action: #selector(copyRepresentedString(_:)), representedObject: project.name))
        if let workingDir = project.workingDir {
            menu.addItem(actionItem(tr("Copy Path"), action: #selector(copyRepresentedString(_:)), representedObject: workingDir))
        }
    }

    private func actionItem(_ title: String, action: Selector, representedObject: Any?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.isEnabled = enabled
        return item
    }

    @objc private func startContainer(_ sender: NSMenuItem) { represented(sender, DockerContainer.self) { viewModel.requestAction(.startContainer($0)) } }
    @objc private func stopContainer(_ sender: NSMenuItem) { represented(sender, DockerContainer.self) { viewModel.requestAction(.stopContainer($0)) } }
    @objc private func restartContainer(_ sender: NSMenuItem) { represented(sender, DockerContainer.self) { viewModel.requestAction(.restartContainer($0)) } }
    @objc private func pauseContainer(_ sender: NSMenuItem) { represented(sender, DockerContainer.self) { viewModel.requestAction(.pauseContainer($0)) } }
    @objc private func killContainer(_ sender: NSMenuItem) { represented(sender, DockerContainer.self) { viewModel.requestAction(.killContainer($0)) } }
    @objc private func deleteContainer(_ sender: NSMenuItem) { represented(sender, DockerContainer.self) { viewModel.requestAction(.deleteContainer($0)) } }
    @objc private func containerLogs(_ sender: NSMenuItem) { represented(sender, DockerContainer.self) { viewModel.loadContainerLogs($0) } }
    @objc private func openContainerShell(_ sender: NSMenuItem) { represented(sender, DockerContainer.self, onOpenContainerShell) }
    @objc private func composeUp(_ sender: NSMenuItem) { represented(sender, DockerComposeProject.self) { viewModel.requestAction(.composeUp($0)) } }
    @objc private func composeDown(_ sender: NSMenuItem) { represented(sender, DockerComposeProject.self) { viewModel.requestAction(.composeDown($0)) } }
    @objc private func composeRestart(_ sender: NSMenuItem) { represented(sender, DockerComposeProject.self) { viewModel.requestAction(.composeRestart($0)) } }
    @objc private func composePause(_ sender: NSMenuItem) { represented(sender, DockerComposeProject.self) { viewModel.requestAction(.composePause($0)) } }
    @objc private func composeKill(_ sender: NSMenuItem) { represented(sender, DockerComposeProject.self) { viewModel.requestAction(.composeKill($0)) } }
    @objc private func composeLogs(_ sender: NSMenuItem) { represented(sender, DockerComposeProject.self) { viewModel.loadComposeLogs($0) } }
    @objc private func deleteVolume(_ sender: NSMenuItem) { represented(sender, DockerVolume.self) { viewModel.requestAction(.deleteVolume($0)) } }
    @objc private func deleteImage(_ sender: NSMenuItem) { represented(sender, DockerImage.self) { viewModel.requestAction(.deleteImage($0)) } }
    @objc private func deleteNetwork(_ sender: NSMenuItem) { represented(sender, DockerNetwork.self) { viewModel.requestAction(.deleteNetwork($0)) } }

    @objc private func copyRepresentedString(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        viewModel.presentToast(tr("Copied"))
    }

    private func represented<T>(_ sender: NSMenuItem, _ type: T.Type, _ action: (T) -> Void) {
        guard let value = sender.representedObject as? T else { return }
        action(value)
    }

    private func composeSummary(for container: DockerContainer) -> String {
        if let project = container.composeProject, let service = container.composeService {
            return "\(project)/\(service)"
        }
        if let project = container.composeProject {
            return project
        }
        return dash
    }

    private func containerSort(_ lhs: DockerContainer, _ rhs: DockerContainer) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

@MainActor
private final class DockerResourceDetailController: NSViewController {
    var selection: DockerResourceSelection? {
        didSet { reload() }
    }

    private let viewModel: DockerPanelViewModel
    private let scrollView = NSScrollView()
    private let detailDocumentView = DockerDetailDocumentView()
    private let stackView = NSStackView()

    init(viewModel: DockerPanelViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = detailDocumentView

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        stackView.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        detailDocumentView.translatesAutoresizingMaskIntoConstraints = false
        detailDocumentView.addSubview(stackView)

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            detailDocumentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stackView.leadingAnchor.constraint(equalTo: detailDocumentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: detailDocumentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: detailDocumentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: detailDocumentView.bottomAnchor),
        ])
        view = container
    }

    func reload() {
        guard isViewLoaded else { return }
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if viewModel.selectedTab.isKubernetesPendingFeature {
            addComingSoon()
            return
        }

        guard let selection else {
            addNoSelection()
            return
        }

        switch selection {
        case .container(let container):
            if viewModel.details(for: container.id) == nil {
                viewModel.ensureContainerDetails(container)
            }
            addHeader(title: container.name, subtitle: container.image, systemImage: "cube.box.fill", copyValue: container.name)
            addSection(tr("Info"), rows: [
                DockerDetailRow(tr("Status"), container.status),
                DockerDetailRow(tr("ID"), container.id, copyValue: container.id),
                DockerDetailRow(tr("Image"), container.image, copyValue: container.image),
                DockerDetailRow(tr("Ports"), container.ports ?? dash, copyValue: container.ports),
                DockerDetailRow(tr("Compose"), container.composeProject ?? dash, copyValue: container.composeProject),
            ])
            if let details = viewModel.details(for: container.id) {
                addSection(tr("Details"), rows: [
                    DockerDetailRow(tr("Command"), details.command ?? dash, copyValue: details.command),
                    DockerDetailRow(tr("Working Dir"), details.workingDir ?? dash),
                    DockerDetailRow(tr("Entrypoint"), details.entrypoint ?? dash),
                    DockerDetailRow(tr("Restart Count"), details.restartCount.map(String.init) ?? dash),
                    DockerDetailRow(tr("Mounts"), details.mounts.isEmpty ? dash : details.mounts.joined(separator: "\n")),
                    DockerDetailRow(tr("Networks"), details.networks.isEmpty ? dash : details.networks.joined(separator: "\n")),
                ])
            } else {
                addMutedText(tr("Loading container details..."))
            }
        case .compose(let project):
            let containers = viewModel.containers.filter { $0.composeProject == project.name }
            addHeader(
                title: project.name,
                subtitle: String(format: tr("%d containers"), containers.count),
                systemImage: "square.stack.3d.up.fill",
                copyValue: project.name
            )
            addSection(tr("Info"), rows: [
                DockerDetailRow(tr("Status"), project.status ?? dash),
                DockerDetailRow(tr("Services"), project.serviceCount.map(String.init) ?? "\(containers.count)"),
                DockerDetailRow(tr("Working Dir"), project.workingDir ?? dash),
                DockerDetailRow(tr("Compose Files"), project.configFiles.isEmpty ? dash : project.configFiles.joined(separator: "\n")),
            ])
            addSection(tr("Containers"), rows: containers.map { DockerDetailRow($0.name, $0.stateBadgeLabel) })
        case .volume(let volume):
            addHeader(title: volume.name, subtitle: volume.driver ?? dash, systemImage: "externaldrive")
            addSection(tr("Info"), rows: [
                DockerDetailRow(tr("Name"), volume.name),
                DockerDetailRow(tr("Driver"), volume.driver ?? dash),
                DockerDetailRow(tr("Scope"), volume.scope ?? dash),
                DockerDetailRow(tr("Mountpoint"), volume.mountpoint ?? dash),
            ])
        case .image(let image):
            addHeader(title: image.displayName, subtitle: image.size ?? dash, systemImage: "cube.transparent.fill")
            addSection(tr("Info"), rows: [
                DockerDetailRow(tr("Repository"), image.repository),
                DockerDetailRow(tr("Tag"), image.tag),
                DockerDetailRow(tr("ID"), image.imageID),
                DockerDetailRow(tr("Digest"), image.digest ?? dash),
                DockerDetailRow(tr("Created"), image.createdSince ?? image.createdAt ?? dash),
                DockerDetailRow(tr("Size"), image.size ?? dash),
            ])
        case .network(let network):
            addHeader(title: network.name, subtitle: network.subnet ?? network.driver ?? dash, systemImage: "network")
            addSection(tr("Info"), rows: [
                DockerDetailRow(tr("ID"), network.id),
                DockerDetailRow(tr("Driver"), network.driver ?? dash),
                DockerDetailRow(tr("Scope"), network.scope ?? dash),
                DockerDetailRow(tr("Subnet"), network.subnet ?? dash),
                DockerDetailRow(tr("Gateway"), network.gateway ?? dash),
            ])
        case .activity(let stat):
            addHeader(title: stat.name, subtitle: String(format: "%.1f%% CPU", stat.cpuPercent), systemImage: "chart.xyaxis.line")
            addSection(tr("Info"), rows: [
                DockerDetailRow(tr("CPU %"), String(format: "%.1f", stat.cpuPercent)),
                DockerDetailRow(tr("Memory"), stat.memoryUsage),
                DockerDetailRow(tr("Network"), stat.networkIO),
                DockerDetailRow(tr("Disk"), stat.blockIO),
                DockerDetailRow(tr("PIDs"), stat.pids ?? dash),
            ])
        case .placeholder(let title, let subtitle):
            addHeader(title: title, subtitle: subtitle, systemImage: "exclamationmark.triangle")
        }
    }

    private func addNoSelection() {
        let label = NSTextField(labelWithString: tr("No Selection"))
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -36).isActive = true
    }

    private func addComingSoon() {
        let view = DockerComingSoonView(
            title: tr("Stay Tuned"),
            subtitle: tr("Kubernetes features are in development"),
            systemImage: "atom"
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -36),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func addHeader(title: String, subtitle: String, systemImage: String, copyValue: String? = nil) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 18, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.addArrangedSubview(titleField)
        if let copyValue, !copyValue.isEmpty, copyValue != dash {
            titleRow.addArrangedSubview(copyButton(copyValue: copyValue))
        }

        let subtitleField = NSTextField(labelWithString: subtitle.isEmpty ? dash : subtitle)
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle

        textStack.addArrangedSubview(titleRow)
        textStack.addArrangedSubview(subtitleField)
        row.addArrangedSubview(imageView)
        row.addArrangedSubview(textStack)
        stackView.addArrangedSubview(row)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.heightAnchor.constraint(equalToConstant: 36),
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -36),
        ])
    }

    private func addSection(_ title: String, rows: [DockerDetailRow]) {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        section.addArrangedSubview(titleField)

        for row in rows {
            section.addArrangedSubview(detailRow(title: row.title, value: row.value, copyValue: row.copyValue))
        }

        stackView.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -36).isActive = true
    }

    private func detailRow(title: String, value: String, copyValue: String?) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let valueField = NSTextField(wrappingLabelWithString: value.isEmpty ? dash : value)
        valueField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = .labelColor
        valueField.allowsEditingTextAttributes = false
        valueField.isSelectable = true
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(titleField)
        row.addArrangedSubview(valueField)
        if let copyValue, !copyValue.isEmpty, copyValue != dash {
            row.addArrangedSubview(copyButton(copyValue: copyValue))
        }
        titleField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        return row
    }

    private func addMutedText(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(label)
    }

    private func copyButton(copyValue: String) -> NSButton {
        let button = DockerCopyButton(copyValue: copyValue)
        button.title = ""
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: tr("Copy"))
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.bezelStyle = .regularSquare
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(handleCopyButton(_:))
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    @objc private func handleCopyButton(_ sender: NSButton) {
        guard let value = (sender as? DockerCopyButton)?.copyValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        viewModel.presentToast(tr("Copied"))
    }
}

private struct DockerDetailRow {
    let title: String
    let value: String
    let copyValue: String?

    init(_ title: String, _ value: String, copyValue: String? = nil) {
        self.title = title
        self.value = value
        self.copyValue = copyValue
    }
}

private final class DockerDetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class DockerCopyButton: NSButton {
    let copyValue: String

    init(copyValue: String) {
        self.copyValue = copyValue
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.copyValue = ""
        super.init(coder: coder)
    }
}

private struct DockerResourceRow {
    let id: String
    let title: String
    let groupTitle: String?
    let selection: DockerResourceSelection
    let icon: NSImage?
    let tint: NSColor?

    var isGroup: Bool {
        groupTitle != nil
    }

    static func group(_ title: String) -> DockerResourceRow {
        DockerResourceRow(
            id: "group-\(title)",
            title: title,
            groupTitle: title,
            selection: .placeholder(title: title, subtitle: ""),
            icon: nil,
            tint: nil
        )
    }

    static func container(_ container: DockerContainer) -> DockerResourceRow {
        DockerResourceRow(
            id: "container-\(container.id)",
            title: container.name,
            groupTitle: nil,
            selection: .container(container),
            icon: NSImage(systemSymbolName: "cube.box.fill", accessibilityDescription: container.name),
            tint: container.isRunning ? .systemGreen : .secondaryLabelColor
        )
    }

    static func compose(_ project: DockerComposeProject) -> DockerResourceRow {
        DockerResourceRow(
            id: "compose-\(project.name)",
            title: project.name,
            groupTitle: nil,
            selection: .compose(project),
            icon: NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: project.name),
            tint: .systemPurple
        )
    }

    static func volume(_ volume: DockerVolume) -> DockerResourceRow {
        DockerResourceRow(
            id: "volume-\(volume.id)",
            title: volume.name,
            groupTitle: nil,
            selection: .volume(volume),
            icon: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: volume.name),
            tint: .systemTeal
        )
    }

    static func image(_ image: DockerImage) -> DockerResourceRow {
        DockerResourceRow(
            id: "image-\(image.id)",
            title: image.displayName,
            groupTitle: nil,
            selection: .image(image),
            icon: NSImage(systemSymbolName: "cube.transparent.fill", accessibilityDescription: image.displayName),
            tint: .systemBlue
        )
    }

    static func network(_ network: DockerNetwork) -> DockerResourceRow {
        DockerResourceRow(
            id: "network-\(network.id)",
            title: network.name,
            groupTitle: nil,
            selection: .network(network),
            icon: NSImage(systemSymbolName: "network", accessibilityDescription: network.name),
            tint: .systemIndigo
        )
    }

    static func activity(_ stat: DockerContainerStats) -> DockerResourceRow {
        DockerResourceRow(
            id: "activity-\(stat.containerID)",
            title: stat.name,
            groupTitle: nil,
            selection: .activity(stat),
            icon: NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: stat.name),
            tint: .systemRed
        )
    }

    static func placeholder(title: String, subtitle: String) -> DockerResourceRow {
        DockerResourceRow(
            id: "placeholder-\(title)",
            title: title,
            groupTitle: nil,
            selection: .placeholder(title: title, subtitle: subtitle),
            icon: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: title),
            tint: .secondaryLabelColor
        )
    }
}

private struct DockerTableColumnSpec {
    let id: String
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
}

private enum DockerCellFactory {
    @MainActor
    static func makeTextCell(identifier: NSUserInterfaceItemIdentifier, leading: CGFloat) -> NSTableCellView {
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
            imageView.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: leading),
            imageView.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: result.centerYAnchor),
        ])
        return result
    }
}

private extension DockerPanelSelection {
    var title: String {
        switch self {
        case .containers: return tr("Containers")
        case .volumes: return tr("Volumes")
        case .images: return tr("Images")
        case .networks: return tr("Networks")
        case .kubernetesPods: return tr("Pods")
        case .kubernetesServices: return tr("Services")
        case .machines: return tr("Machines")
        case .activityMonitor: return tr("Activity Monitor")
        case .commands: return tr("Commands")
        }
    }

    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .volumes: return "externaldrive"
        case .images: return "doc.on.clipboard"
        case .networks: return "network"
        case .kubernetesPods: return "atom"
        case .kubernetesServices: return "globe"
        case .machines: return "desktopcomputer"
        case .activityMonitor: return "chart.xyaxis.line"
        case .commands: return "terminal"
        }
    }
}

private let dash = "-"
