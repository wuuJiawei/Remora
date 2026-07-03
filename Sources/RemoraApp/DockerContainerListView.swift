import AppKit

@MainActor
final class DockerContainerListView: NSViewController {
    var onSelectionChanged: ((DockerResourceSelection?) -> Void)? {
        didSet {
            outlineController.onSelectionChanged = onSelectionChanged
        }
    }

    private let outlineController: DockerContainerOutlineView

    init(
        panelViewModel: DockerPanelViewModel,
        onOpenContainerShell: @escaping (DockerContainer) -> Void
    ) {
        let listViewModel = DockerContainerListViewModel(
            panelViewModel: panelViewModel,
            onOpenContainerShell: onOpenContainerShell
        )
        self.outlineController = DockerContainerOutlineView(listViewModel: listViewModel)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(outlineController)
        view.addSubview(outlineController.view)
        outlineController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outlineController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outlineController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outlineController.view.topAnchor.constraint(equalTo: view.topAnchor),
            outlineController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func reload(
        containers: [DockerContainer],
        composeProjects: [DockerComposeProject],
        isLoading: Bool
    ) {
        let nodes = DockerContainerTreeBuilder.buildContainerTree(
            containers: containers,
            composeProjects: composeProjects
        )
        outlineController.reload(
            nodes: nodes,
            isLoading: isLoading,
            emptyMessage: isLoading ? tr("Loading...") : tr("No Docker containers were returned by the current server.")
        )
    }
}
