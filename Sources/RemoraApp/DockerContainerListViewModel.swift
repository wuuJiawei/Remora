import AppKit

@MainActor
final class DockerContainerListViewModel {
    private let panelViewModel: DockerPanelViewModel
    private let onOpenContainerShell: (DockerContainer) -> Void

    init(
        panelViewModel: DockerPanelViewModel,
        onOpenContainerShell: @escaping (DockerContainer) -> Void
    ) {
        self.panelViewModel = panelViewModel
        self.onOpenContainerShell = onOpenContainerShell
    }

    func startContainer(_ container: DockerContainer) {
        panelViewModel.requestAction(.startContainer(container))
    }

    func stopContainer(_ container: DockerContainer) {
        panelViewModel.requestAction(.stopContainer(container))
    }

    func restartContainer(_ container: DockerContainer) {
        panelViewModel.requestAction(.restartContainer(container))
    }

    func pauseContainer(_ container: DockerContainer) {
        panelViewModel.requestAction(.pauseContainer(container))
    }

    func killContainer(_ container: DockerContainer) {
        panelViewModel.requestAction(.killContainer(container))
    }

    func removeContainer(_ container: DockerContainer) {
        panelViewModel.requestAction(.deleteContainer(container))
    }

    func openContainerLogs(_ container: DockerContainer) {
        panelViewModel.loadContainerLogs(container)
    }

    func openContainerShell(_ container: DockerContainer) {
        guard container.isRunning else {
            panelViewModel.presentToast(tr("Container is not running, so a shell cannot be opened"))
            return
        }
        onOpenContainerShell(container)
    }

    func startCompose(_ project: DockerComposeProject) {
        panelViewModel.requestAction(.composeUp(project))
    }

    func stopCompose(_ project: DockerComposeProject) {
        panelViewModel.requestAction(.composeDown(project))
    }

    func restartCompose(_ project: DockerComposeProject) {
        panelViewModel.requestAction(.composeRestart(project))
    }

    func pauseCompose(_ project: DockerComposeProject) {
        panelViewModel.requestAction(.composePause(project))
    }

    func killCompose(_ project: DockerComposeProject) {
        panelViewModel.requestAction(.composeKill(project))
    }

    func removeCompose(_ project: DockerComposeProject) {
        panelViewModel.requestAction(.composeDown(project))
    }

    func openComposeLogs(_ project: DockerComposeProject) {
        panelViewModel.loadComposeLogs(project)
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        panelViewModel.presentToast(tr("Copied"))
    }
}
