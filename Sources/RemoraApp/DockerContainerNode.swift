import Foundation

enum DockerContainerNodeKind: Equatable, Sendable {
    case section
    case compose
    case container
}

enum DockerContainerNodeState: Equatable, Sendable {
    case running
    case stopped
}

struct DockerContainerNode: Identifiable, Equatable, Sendable {
    let id: String
    let kind: DockerContainerNodeKind
    let title: String
    let subtitle: String?
    let state: DockerContainerNodeState?
    let container: DockerContainer?
    let composeProject: DockerComposeProject?
    let children: [DockerContainerNode]

    var isRunning: Bool {
        state == .running
    }

    static func section(
        id: String,
        title: String,
        children: [DockerContainerNode]
    ) -> DockerContainerNode {
        DockerContainerNode(
            id: id,
            kind: .section,
            title: title,
            subtitle: nil,
            state: nil,
            container: nil,
            composeProject: nil,
            children: children
        )
    }

    static func compose(
        project: DockerComposeProject,
        state: DockerContainerNodeState,
        children: [DockerContainerNode]
    ) -> DockerContainerNode {
        DockerContainerNode(
            id: "compose-\(state)-\(project.name)",
            kind: .compose,
            title: project.name,
            subtitle: project.status,
            state: state,
            container: nil,
            composeProject: project,
            children: children
        )
    }

    static func container(
        _ container: DockerContainer,
        state: DockerContainerNodeState
    ) -> DockerContainerNode {
        DockerContainerNode(
            id: "container-\(container.id)",
            kind: .container,
            title: container.name,
            subtitle: container.image,
            state: state,
            container: container,
            composeProject: nil,
            children: []
        )
    }
}
