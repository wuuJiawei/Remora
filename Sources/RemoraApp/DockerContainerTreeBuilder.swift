import Foundation

enum DockerContainerTreeBuilder {
    static func buildContainerTree(
        containers: [DockerContainer],
        composeProjects: [DockerComposeProject]
    ) -> [DockerContainerNode] {
        let projectsByName = Dictionary(uniqueKeysWithValues: composeProjects.map { ($0.name, $0) })
        let running = buildSection(
            id: "running",
            title: tr("Running"),
            state: .running,
            containers: containers.filter(\.isRunning),
            projectsByName: projectsByName
        )
        let stopped = buildSection(
            id: "stopped",
            title: tr("Stopped"),
            state: .stopped,
            containers: containers.filter { !$0.isRunning },
            projectsByName: projectsByName
        )
        return [running, stopped].compactMap { $0 }
    }

    private static func buildSection(
        id: String,
        title: String,
        state: DockerContainerNodeState,
        containers: [DockerContainer],
        projectsByName: [String: DockerComposeProject]
    ) -> DockerContainerNode? {
        guard !containers.isEmpty else { return nil }

        let grouped = Dictionary(grouping: containers) { $0.composeProject ?? "" }
        let composeNodes = grouped.keys
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { projectName in
                let project = projectsByName[projectName] ?? DockerComposeProject(
                    name: projectName,
                    status: nil,
                    configFiles: [],
                    workingDir: nil,
                    serviceCount: grouped[projectName]?.count
                )
                let children = (grouped[projectName] ?? [])
                    .sorted(by: sortContainers)
                    .map { DockerContainerNode.container($0, state: state) }
                return DockerContainerNode.compose(project: project, state: state, children: children)
            }

        let standaloneNodes = (grouped[""] ?? [])
            .sorted(by: sortContainers)
            .map { DockerContainerNode.container($0, state: state) }

        return DockerContainerNode.section(
            id: "section-\(id)",
            title: title,
            children: composeNodes + standaloneNodes
        )
    }

    private static func sortContainers(_ lhs: DockerContainer, _ rhs: DockerContainer) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
