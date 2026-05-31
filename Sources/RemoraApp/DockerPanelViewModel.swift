import Foundation
import RemoraCore

@MainActor
final class DockerPanelViewModel: ObservableObject {
    @Published private(set) var runtimeBinding = DockerRuntimeBinding.disconnected
    @Published var selectedTab: DockerPanelSelection = .containers
    @Published private(set) var environment = DockerEnvironmentStatus.disconnected
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var images: [DockerImage] = []
    @Published private(set) var composeProjects: [DockerComposeProject] = []
    @Published private(set) var containerDetails: [String: DockerContainerDetails] = [:]
    @Published private(set) var isLoadingEnvironment = false
    @Published private(set) var isLoadingContainers = false
    @Published private(set) var isLoadingImages = false
    @Published private(set) var isLoadingCompose = false
    @Published private(set) var isPerformingAction = false
    @Published private(set) var activeLog: DockerLogSnapshot?
    @Published private(set) var isLoadingLogs = false
    @Published var logTailLineCount = 300
    @Published var pendingConfirmationAction: DockerPanelAction?
    @Published var toastMessage: String?
    @Published var selectedContainerID: String?
    @Published var selectedComposeProjectName: String?
    @Published var containerFilterText = ""
    @Published var imageFilterText = ""
    @Published var composeFilterText = ""
    @Published var liveLogSession: DockerLiveLogSession?

    private let service: DockerCommandService
    private var target: DockerCommandService.ShellTarget?
    private var refreshTask: Task<Void, Never>?
    private var toastHideTask: Task<Void, Never>?

    init(service: DockerCommandService = DockerCommandService()) {
        self.service = service
    }

    func updateRuntimeBinding(_ binding: DockerRuntimeBinding) {
        let previous = self.runtimeBinding
        self.runtimeBinding = binding

        if previous.runtimeID == binding.runtimeID,
           previous.connectionState == binding.connectionState,
           previous.host == binding.host,
           previous.executionMode == binding.executionMode
        {
            return
        }

        if binding.connectionMode != .ssh || binding.host == nil || binding.connectionState.hasPrefix("Connected") == false {
            target = nil
            environment = .disconnected
            containers = []
            images = []
            composeProjects = []
            containerDetails = [:]
            activeLog = nil
            isLoadingEnvironment = false
            isLoadingContainers = false
            isLoadingImages = false
            isLoadingCompose = false
            isLoadingLogs = false
            return
        }

        guard let host = binding.host else { return }
        let client: SFTPClientProtocol
        switch binding.executionMode {
        case .directHost:
            client = SystemSFTPClient(host: host)
        case .requireExistingSSHConnection:
            client = SystemSFTPClient(
                host: host,
                connectionReuseMode: .requireExistingConnection
            )
        }
        target = .init(host: host, client: client)
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        guard let target else {
            environment = .disconnected
            containers = []
            images = []
            composeProjects = []
            containerDetails = [:]
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadAll(target: target)
        }
    }

    func loadContainerLogs(_ container: DockerContainer) {
        guard let target else { return }
        liveLogSession = DockerLiveLogSession(
            title: container.name,
            subtitle: container.image,
            lineCount: logTailLineCount,
            loadLatest: { [service] lineCount in
                try await service.containerLogs(
                    containerID: container.id,
                    tail: lineCount,
                    target: target
                )
            },
            stream: { [service] lineCount in
                try await service.streamContainerLogs(
                    containerID: container.id,
                    tail: lineCount,
                    target: target
                )
            }
        )
    }

    func loadComposeLogs(_ project: DockerComposeProject) {
        guard let target else { return }
        liveLogSession = DockerLiveLogSession(
            title: project.name,
            subtitle: project.workingDir ?? project.status,
            lineCount: logTailLineCount,
            loadLatest: { [service] lineCount in
                try await service.composeLogs(
                    project: project,
                    tail: lineCount,
                    target: target
                )
            },
            stream: { [service] lineCount in
                try await service.streamComposeLogs(
                    project: project,
                    tail: lineCount,
                    target: target
                )
            }
        )
    }

    func clearLogs() {
        activeLog = nil
        liveLogSession = nil
    }

    func dismissLiveLogSession() {
        liveLogSession = nil
    }

    func refreshActiveLog() {
        guard let activeLog else { return }

        switch activeLog.source {
        case .container(let id, _):
            guard let container = containers.first(where: { $0.id == id }) else { return }
            loadContainerLogs(container)
        case .compose(let projectName):
            guard let project = composeProjects.first(where: { $0.name == projectName }) else { return }
            loadComposeLogs(project)
        }
    }

    func requestAction(_ action: DockerPanelAction) {
        if action.confirmationTitle == nil {
            performAction(action)
        } else {
            pendingConfirmationAction = action
        }
    }

    func confirmPendingAction() {
        guard let action = pendingConfirmationAction else { return }
        pendingConfirmationAction = nil
        performAction(action)
    }

    func cancelPendingAction() {
        pendingConfirmationAction = nil
    }

    func details(for containerID: String) -> DockerContainerDetails? {
        containerDetails[containerID]
    }

    func ensureContainerDetails(_ container: DockerContainer) {
        guard containerDetails[container.id] == nil else { return }
        guard let target else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let details = try await service.inspectContainer(id: container.id, target: target)
                guard !Task.isCancelled else { return }
                containerDetails[container.id] = details
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    var filteredContainers: [DockerContainer] {
        let query = normalizedFilter(containerFilterText)
        guard !query.isEmpty else { return containers }
        return containers.filter { container in
            [
                container.name,
                container.image,
                container.command,
                container.status,
                container.state,
                container.ports,
                container.composeProject,
                container.composeService,
                container.shortID,
            ]
            .compactMap { $0?.lowercased() }
            .contains(where: { $0.contains(query) })
        }
    }

    var filteredImages: [DockerImage] {
        let query = normalizedFilter(imageFilterText)
        guard !query.isEmpty else { return images }
        return images.filter { image in
            let searchable: [String?] = [
                image.repository,
                image.tag,
                image.imageID,
                image.digest,
                image.size,
                image.createdSince,
            ]
            return searchable
                .compactMap { $0?.lowercased() }
                .contains(where: { $0.contains(query) })
        }
    }

    var filteredComposeProjects: [DockerComposeProject] {
        let query = normalizedFilter(composeFilterText)
        guard !query.isEmpty else { return composeProjects }
        return composeProjects.filter { project in
            let searchable = [
                project.name,
                project.status,
                project.workingDir,
            ] + project.configFiles
            return searchable
                .compactMap { $0?.lowercased() }
                .contains(where: { $0.contains(query) })
        }
    }

    private func performAction(_ action: DockerPanelAction) {
        guard let target else { return }
        isPerformingAction = true
        showToast(action.progressMessage)

        Task { [weak self] in
            guard let self else { return }
            defer { isPerformingAction = false }

            do {
                switch action {
                case .startContainer(let container):
                    try await service.startContainer(id: container.id, target: target)
                case .stopContainer(let container):
                    try await service.stopContainer(id: container.id, target: target)
                case .restartContainer(let container):
                    try await service.restartContainer(id: container.id, target: target)
                case .composeUp(let project):
                    try await service.composeUp(project: project, target: target)
                case .composeDown(let project):
                    try await service.composeDown(project: project, target: target)
                case .composeRestart(let project):
                    try await service.composeRestart(project: project, target: target)
                }

                await reloadAll(target: target)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func reloadAll(target: DockerCommandService.ShellTarget) async {
        isLoadingEnvironment = true
        isLoadingContainers = true
        isLoadingImages = true
        isLoadingCompose = true

        do {
            let environment = try await service.checkEnvironment(target: target)
            guard !Task.isCancelled else { return }
            self.environment = environment
        } catch {
            self.environment = DockerEnvironmentStatus(
                dockerAvailable: false,
                composeAvailable: false,
                dockerVersion: nil,
                composeVersion: nil,
                dockerIssue: .commandFailed(error.localizedDescription),
                composeIssue: .commandFailed(error.localizedDescription)
            )
        }
        isLoadingEnvironment = false

        if environment.dockerAvailable {
            do {
                containers = try await service.listContainers(target: target)
            } catch {
                containers = []
                showToast(error.localizedDescription)
            }
            do {
                images = try await service.listImages(target: target)
            } catch {
                images = []
                showToast(error.localizedDescription)
            }
        } else {
            containers = []
            images = []
        }
        isLoadingContainers = false
        isLoadingImages = false

        if environment.composeAvailable {
            do {
                composeProjects = try await service.listComposeProjects(target: target)
            } catch {
                composeProjects = []
                showToast(error.localizedDescription)
            }
        } else {
            composeProjects = []
        }
        isLoadingCompose = false
    }

    private func normalizedFilter(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func showToast(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        toastHideTask?.cancel()
        toastMessage = trimmed
        toastHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard let self, !Task.isCancelled else { return }
            self.toastMessage = nil
            self.toastHideTask = nil
        }
    }

    func presentToast(_ message: String) {
        showToast(message)
    }
}
