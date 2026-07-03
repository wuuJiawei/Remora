import Foundation
import RemoraCore

enum DockerConnectionExecutionMode: Equatable, Sendable {
    case directHost
    case requireExistingSSHConnection
}

enum DockerPanelSelection: String, CaseIterable, Identifiable, Sendable {
    case containers = "containers"
    case volumes = "volumes"
    case images = "images"
    case networks = "networks"
    case kubernetesPods = "kubernetesPods"
    case kubernetesServices = "kubernetesServices"
    case machines = "machines"
    case activityMonitor = "activityMonitor"
    case commands = "commands"

    var id: String { rawValue }

    var isKubernetesPendingFeature: Bool {
        switch self {
        case .kubernetesPods, .kubernetesServices:
            return true
        case .containers, .volumes, .images, .networks, .machines, .activityMonitor, .commands:
            return false
        }
    }
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

struct DockerVolume: Identifiable, Equatable, Sendable {
    let name: String
    let driver: String?
    let scope: String?
    let mountpoint: String?
    let labels: [String: String]

    var id: String { name }
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

struct DockerNetwork: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let driver: String?
    let scope: String?
    let subnet: String?
    let gateway: String?
    let labels: [String: String]

    var shortID: String {
        String(id.prefix(12))
    }
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

struct DockerContainerStats: Identifiable, Equatable, Sendable {
    let containerID: String
    let name: String
    let cpuPercent: Double
    let memoryUsage: String
    let memoryUsageBytes: Int64
    let memoryPercent: Double?
    let networkIO: String
    let networkIOBytes: Int64
    let blockIO: String
    let blockIOBytes: Int64
    let pids: String?
    let pidsValue: Int?

    var id: String { containerID }
}

struct DockerActivitySnapshot: Equatable, Sendable {
    let stats: [DockerContainerStats]
    let fetchedAt: Date

    static let empty = DockerActivitySnapshot(stats: [], fetchedAt: .distantPast)

    var totalCPUPercent: Double {
        stats.reduce(0) { $0 + $1.cpuPercent }
    }

    var totalMemoryUsage: String {
        let values = stats.map(\.memoryUsage).filter { !$0.isEmpty && $0 != "0B" }
        return values.isEmpty ? "0 B" : values.joined(separator: " + ")
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
    case pauseContainer(DockerContainer)
    case killContainer(DockerContainer)
    case deleteContainer(DockerContainer)
    case composeUp(DockerComposeProject)
    case composeDown(DockerComposeProject)
    case composeRestart(DockerComposeProject)
    case composePause(DockerComposeProject)
    case composeKill(DockerComposeProject)
    case deleteVolume(DockerVolume)
    case deleteImage(DockerImage)
    case deleteNetwork(DockerNetwork)

    var confirmationTitle: String? {
        switch self {
        case .stopContainer(let container):
            return String(format: tr("Stop container \"%@\"?"), container.name)
        case .restartContainer(let container):
            return String(format: tr("Restart container \"%@\"?"), container.name)
        case .pauseContainer(let container):
            return String(format: tr("Pause container \"%@\"?"), container.name)
        case .killContainer(let container):
            return String(format: tr("Kill container \"%@\"?"), container.name)
        case .deleteContainer(let container):
            return String(format: tr("Delete container \"%@\"?"), container.name)
        case .composeDown(let project):
            return String(format: tr("Run Compose down for \"%@\"?"), project.name)
        case .composeRestart(let project):
            return String(format: tr("Restart Compose project \"%@\"?"), project.name)
        case .composePause(let project):
            return String(format: tr("Pause Compose project \"%@\"?"), project.name)
        case .composeKill(let project):
            return String(format: tr("Kill Compose project \"%@\"?"), project.name)
        case .deleteVolume(let volume):
            return String(format: tr("Delete volume \"%@\"?"), volume.name)
        case .deleteImage(let image):
            return String(format: tr("Delete image \"%@\"?"), image.displayName)
        case .deleteNetwork(let network):
            return String(format: tr("Delete network \"%@\"?"), network.name)
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
        case .pauseContainer(let container):
            return String(format: tr("Pausing container \"%@\"..."), container.name)
        case .killContainer(let container):
            return String(format: tr("Killing container \"%@\"..."), container.name)
        case .deleteContainer(let container):
            return String(format: tr("Deleting container \"%@\"..."), container.name)
        case .composeUp(let project):
            return String(format: tr("Running Compose up for \"%@\"..."), project.name)
        case .composeDown(let project):
            return String(format: tr("Running Compose down for \"%@\"..."), project.name)
        case .composeRestart(let project):
            return String(format: tr("Restarting Compose project \"%@\"..."), project.name)
        case .composePause(let project):
            return String(format: tr("Pausing Compose project \"%@\"..."), project.name)
        case .composeKill(let project):
            return String(format: tr("Killing Compose project \"%@\"..."), project.name)
        case .deleteVolume(let volume):
            return String(format: tr("Deleting volume \"%@\"..."), volume.name)
        case .deleteImage(let image):
            return String(format: tr("Deleting image \"%@\"..."), image.displayName)
        case .deleteNetwork(let network):
            return String(format: tr("Deleting network \"%@\"..."), network.name)
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
