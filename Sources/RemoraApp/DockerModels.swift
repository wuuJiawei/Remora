import Foundation
import RemoraCore

enum DockerConnectionExecutionMode: Equatable, Sendable {
    case directHost
    case requireExistingSSHConnection
}

enum DockerPanelSelection: String, CaseIterable, Identifiable, Sendable {
    case containers = "containers"
    case images = "images"
    case compose = "compose"

    var id: String { rawValue }
}

enum DockerResourceKind: Sendable {
    case container
    case composeProject
}

enum DockerLogSource: Equatable, Sendable {
    case container(id: String, name: String)
    case compose(projectName: String)

    var title: String {
        switch self {
        case .container(_, let name):
            return name
        case .compose(let projectName):
            return projectName
        }
    }
}

enum DockerEnvironmentIssue: Equatable, Sendable {
    case sshDisconnected
    case dockerNotInstalled
    case daemonUnavailable
    case permissionDenied
    case composeUnavailable
    case composeUnsupported
    case commandFailed(String)

    var userMessage: String {
        switch self {
        case .sshDisconnected:
            return tr("Please connect to a server first")
        case .dockerNotInstalled:
            return tr("Docker was not detected on this server")
        case .daemonUnavailable:
            return tr("Docker is installed, but the Docker daemon appears to be unavailable")
        case .permissionDenied:
            return tr("The current user may not have permission to use Docker")
        case .composeUnavailable:
            return tr("Docker Compose was not detected on this server")
        case .composeUnsupported:
            return tr("Docker Compose is available, but this server does not support the requested Compose command")
        case .commandFailed(let message):
            return message
        }
    }
}

struct DockerEnvironmentStatus: Equatable, Sendable {
    var dockerAvailable: Bool
    var composeAvailable: Bool
    var dockerVersion: String?
    var composeVersion: String?
    var dockerIssue: DockerEnvironmentIssue?
    var composeIssue: DockerEnvironmentIssue?

    static let disconnected = DockerEnvironmentStatus(
        dockerAvailable: false,
        composeAvailable: false,
        dockerVersion: nil,
        composeVersion: nil,
        dockerIssue: .sshDisconnected,
        composeIssue: .sshDisconnected
    )
}

struct DockerContainer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let image: String
    let command: String?
    let status: String
    let state: String?
    let ports: String?
    let createdAt: String?
    let runningFor: String?
    let composeProject: String?
    let composeService: String?
    let labels: [String: String]

    var isRunning: Bool {
        let value = (state ?? status).lowercased()
        return value.contains("running") || value.contains("up ")
    }

    var stateBadgeLabel: String {
        if let state, !state.isEmpty {
            return state
        }
        return status
    }

    var shortID: String {
        String(id.prefix(12))
    }
}

struct DockerContainerDetails: Equatable, Sendable {
    let id: String
    let name: String
    let image: String
    let command: String?
    let createdAt: String?
    let status: String?
    let restartCount: Int?
    let workingDir: String?
    let entrypoint: String?
    let ports: [String]
    let mounts: [String]
    let networks: [String]
    let labels: [String: String]
}

struct DockerImage: Identifiable, Equatable, Sendable {
    let repository: String
    let tag: String
    let imageID: String
    let digest: String?
    let createdSince: String?
    let createdAt: String?
    let size: String?

    var displayName: String {
        if repository == "<none>" {
            return "<none>:\(tag)"
        }
        return "\(repository):\(tag)"
    }

    var shortID: String {
        String(imageID.prefix(19))
    }

    var isDangling: Bool {
        repository == "<none>" || tag == "<none>"
    }

    var identity: String {
        "\(repository)|\(tag)|\(imageID)"
    }

    var id: String { identity }
}

struct DockerComposeProject: Identifiable, Equatable, Sendable {
    let name: String
    let status: String?
    let configFiles: [String]
    let workingDir: String?
    let serviceCount: Int?

    var id: String { name }

    var canRunCommands: Bool {
        if let workingDir, !workingDir.isEmpty {
            return true
        }
        return !configFiles.isEmpty
    }
}

struct DockerLogSnapshot: Equatable, Sendable {
    let source: DockerLogSource
    let text: String
    let tail: Int
    let fetchedAt: Date
}

struct DockerLiveLogSession: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let lineCount: Int
    let loadLatest: @Sendable (Int) async throws -> String
    let stream: @Sendable (Int) async throws -> AsyncThrowingStream<String, Error>
}

enum DockerPanelAction: Equatable, Sendable {
    case startContainer(DockerContainer)
    case stopContainer(DockerContainer)
    case restartContainer(DockerContainer)
    case composeUp(DockerComposeProject)
    case composeDown(DockerComposeProject)
    case composeRestart(DockerComposeProject)

    var confirmationTitle: String? {
        switch self {
        case .stopContainer(let container):
            return String(format: tr("Stop container \"%@\"?"), container.name)
        case .restartContainer(let container):
            return String(format: tr("Restart container \"%@\"?"), container.name)
        case .composeDown(let project):
            return String(format: tr("Run Compose down for \"%@\"?"), project.name)
        case .composeRestart(let project):
            return String(format: tr("Restart Compose project \"%@\"?"), project.name)
        case .startContainer, .composeUp:
            return nil
        }
    }

    var progressMessage: String {
        switch self {
        case .startContainer(let container):
            return String(format: tr("Starting container \"%@\"..."), container.name)
        case .stopContainer(let container):
            return String(format: tr("Stopping container \"%@\"..."), container.name)
        case .restartContainer(let container):
            return String(format: tr("Restarting container \"%@\"..."), container.name)
        case .composeUp(let project):
            return String(format: tr("Running Compose up for \"%@\"..."), project.name)
        case .composeDown(let project):
            return String(format: tr("Running Compose down for \"%@\"..."), project.name)
        case .composeRestart(let project):
            return String(format: tr("Restarting Compose project \"%@\"..."), project.name)
        }
    }
}

struct DockerRuntimeBinding: Equatable, Sendable {
    let runtimeID: ObjectIdentifier?
    let connectionMode: ConnectionMode?
    let connectionState: String
    let host: RemoraCore.Host?
    let executionMode: DockerConnectionExecutionMode

    static let disconnected = DockerRuntimeBinding(
        runtimeID: nil,
        connectionMode: nil,
        connectionState: "Disconnected",
        host: nil,
        executionMode: .directHost
    )
}
