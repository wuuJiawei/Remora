import Foundation
import RemoraCore

actor DockerCommandService {
    struct ShellTarget: Sendable {
        let host: RemoraCore.Host
        let client: SFTPClientProtocol
    }

    private struct DockerVersionPayload: Decodable {
        let client: DockerVersionSection?
        let server: DockerVersionSection?

        private enum CodingKeys: String, CodingKey {
            case client = "Client"
            case server = "Server"
        }
    }

    private struct DockerVersionSection: Decodable {
        let version: String?

        private enum CodingKeys: String, CodingKey {
            case version = "Version"
        }
    }

    private struct DockerPSLine: Decodable {
        let id: String?
        let names: String?
        let image: String?
        let command: String?
        let status: String?
        let state: String?
        let ports: String?
        let createdAt: String?
        let runningFor: String?
        let labels: String?

        private enum CodingKeys: String, CodingKey {
            case id = "ID"
            case names = "Names"
            case image = "Image"
            case command = "Command"
            case status = "Status"
            case state = "State"
            case ports = "Ports"
            case createdAt = "CreatedAt"
            case runningFor = "RunningFor"
            case labels = "Labels"
        }
    }

    private struct DockerImageLine: Decodable {
        let repository: String?
        let tag: String?
        let id: String?
        let digest: String?
        let createdSince: String?
        let createdAt: String?
        let size: String?

        private enum CodingKeys: String, CodingKey {
            case repository = "Repository"
            case tag = "Tag"
            case id = "ID"
            case digest = "Digest"
            case createdSince = "CreatedSince"
            case createdAt = "CreatedAt"
            case size = "Size"
        }
    }

    private struct DockerInspectContainer: Decodable {
        let id: String?
        let name: String?
        let image: String?
        let command: [String]?
        let created: String?
        let config: InspectConfig?
        let state: InspectState?
        let networkSettings: InspectNetworkSettings?
        let mounts: [InspectMount]?

        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case image = "Image"
            case command = "Args"
            case created = "Created"
            case config = "Config"
            case state = "State"
            case networkSettings = "NetworkSettings"
            case mounts = "Mounts"
        }
    }

    private struct InspectConfig: Decodable {
        let image: String?
        let workingDir: String?
        let labels: [String: String]?
        let entrypoint: [String]?
        let cmd: [String]?

        private enum CodingKeys: String, CodingKey {
            case image = "Image"
            case workingDir = "WorkingDir"
            case labels = "Labels"
            case entrypoint = "Entrypoint"
            case cmd = "Cmd"
        }
    }

    private struct InspectState: Decodable {
        let status: String?
        let restartCount: Int?

        private enum CodingKeys: String, CodingKey {
            case status = "Status"
            case restartCount = "RestartCount"
        }
    }

    private struct InspectNetworkSettings: Decodable {
        let ports: [String: [InspectPortBinding]?]?
        let networks: [String: InspectNetwork]?

        private enum CodingKeys: String, CodingKey {
            case ports = "Ports"
            case networks = "Networks"
        }
    }

    private struct InspectPortBinding: Decodable {
        let hostIP: String?
        let hostPort: String?

        private enum CodingKeys: String, CodingKey {
            case hostIP = "HostIp"
            case hostPort = "HostPort"
        }
    }

    private struct InspectNetwork: Decodable {}

    private struct InspectMount: Decodable {
        let source: String?
        let destination: String?
        let type: String?
        let mode: String?
        let readWrite: Bool?

        private enum CodingKeys: String, CodingKey {
            case source = "Source"
            case destination = "Destination"
            case type = "Type"
            case mode = "Mode"
            case readWrite = "RW"
        }
    }

    private struct ComposePSLine: Decodable {
        let name: String?
        let status: String?
        let configFiles: String?
        let projectDirectory: String?
        let workingDir: String?
        let serviceCount: Int?

        private enum CodingKeys: String, CodingKey {
            case name = "Name"
            case status = "Status"
            case configFiles = "ConfigFiles"
            case projectDirectory = "ProjectDirectory"
            case workingDir = "WorkingDir"
            case serviceCount = "ServiceCount"
        }
    }

    func checkEnvironment(target: ShellTarget) async throws -> DockerEnvironmentStatus {
        let dockerVersionResult = await runCommand(
            "docker version --format '{{json .}}'",
            on: target,
            timeout: 12
        )

        var dockerAvailable = false
        var dockerVersion: String?
        var dockerIssue: DockerEnvironmentIssue?

        switch dockerVersionResult {
        case .success(let output):
            dockerAvailable = true
            dockerVersion = parseDockerVersion(output)
        case .failure(let error):
            let message = error.localizedDescription
            if isDockerFormatUnsupported(message) {
                let fallback = await runCommand("docker version", on: target, timeout: 12)
                switch fallback {
                case .success(let output):
                    dockerAvailable = true
                    dockerVersion = parseDockerVersionFallback(output)
                case .failure(let fallbackError):
                    dockerIssue = classifyDockerIssue(fallbackError.localizedDescription)
                }
            } else {
                dockerIssue = classifyDockerIssue(message)
            }
        }

        var composeAvailable = false
        var composeVersion: String?
        var composeIssue: DockerEnvironmentIssue?

        if dockerAvailable {
            let composeResult = await runCommand(
                "docker compose version --short",
                on: target,
                timeout: 10
            )
            switch composeResult {
            case .success(let output):
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    composeAvailable = true
                    composeVersion = trimmed
                } else {
                    composeIssue = .composeUnavailable
                }
            case .failure(let error):
                let message = error.localizedDescription
                if isComposeShortUnsupported(message) {
                    let fallback = await runCommand("docker compose version", on: target, timeout: 10)
                    switch fallback {
                    case .success(let output):
                        composeVersion = parseComposeVersionFallback(output)
                        composeAvailable = composeVersion != nil
                        if !composeAvailable {
                            composeIssue = .composeUnsupported
                        }
                    case .failure(let fallbackError):
                        composeIssue = classifyComposeIssue(fallbackError.localizedDescription)
                    }
                } else {
                    composeIssue = classifyComposeIssue(message)
                }
            }
        } else {
            composeIssue = .composeUnavailable
        }

        return DockerEnvironmentStatus(
            dockerAvailable: dockerAvailable,
            composeAvailable: composeAvailable,
            dockerVersion: dockerVersion,
            composeVersion: composeVersion,
            dockerIssue: dockerIssue,
            composeIssue: composeIssue
        )
    }

    func listContainers(target: ShellTarget) async throws -> [DockerContainer] {
        let command = "docker ps -a --format '{{json .}}'"
        let output = try await target.client.executeRemoteShellCommand(command, timeout: 12)
        return parseContainers(output)
    }

    func inspectContainer(id: String, target: ShellTarget) async throws -> DockerContainerDetails {
        let command = "docker inspect \(quoteShellArgument(id))"
        let output = try await target.client.executeRemoteShellCommand(command, timeout: 15)
        return try parseContainerDetails(output, fallbackID: id)
    }

    func containerLogs(containerID: String, tail: Int, target: ShellTarget) async throws -> String {
        let lineCount = max(1, min(tail, 5000))
        let command = "docker logs --tail \(lineCount) \(quoteShellArgument(containerID)) 2>&1"
        return try await target.client.executeRemoteShellCommand(command, timeout: 20)
    }

    func streamContainerLogs(
        containerID: String,
        tail: Int,
        target: ShellTarget
    ) async throws -> AsyncThrowingStream<String, Error> {
        let lineCount = max(1, min(tail, 5000))
        let command = "docker logs --tail \(lineCount) -f \(quoteShellArgument(containerID)) 2>&1"
        return try await target.client.streamRemoteShellCommand(command)
    }

    func startContainer(id: String, target: ShellTarget) async throws {
        let command = "docker start \(quoteShellArgument(id))"
        _ = try await target.client.executeRemoteShellCommand(command, timeout: 20)
    }

    func stopContainer(id: String, target: ShellTarget) async throws {
        let command = "docker stop \(quoteShellArgument(id))"
        _ = try await target.client.executeRemoteShellCommand(command, timeout: 20)
    }

    func restartContainer(id: String, target: ShellTarget) async throws {
        let command = "docker restart \(quoteShellArgument(id))"
        _ = try await target.client.executeRemoteShellCommand(command, timeout: 20)
    }

    func listComposeProjects(target: ShellTarget) async throws -> [DockerComposeProject] {
        let primary = await runCommand("docker compose ls --format json", on: target, timeout: 12)
        switch primary {
        case .success(let output):
            if let parsed = parseComposeProjectsJSON(output) {
                return parsed
            }
            return parseComposeProjectsText(output)
        case .failure(let error):
            let message = error.localizedDescription
            if classifyComposeIssue(message) == .composeUnavailable {
                throw error
            }
            let fallback = try await target.client.executeRemoteShellCommand("docker compose ls", timeout: 12)
            return parseComposeProjectsText(fallback)
        }
    }

    func listImages(target: ShellTarget) async throws -> [DockerImage] {
        let command = "docker images --digests --format '{{json .}}'"
        let output = try await target.client.executeRemoteShellCommand(command, timeout: 12)
        return parseImages(output)
    }

    func composeLogs(project: DockerComposeProject, tail: Int, target: ShellTarget) async throws -> String {
        let lineCount = max(1, min(tail, 5000))
        let command = try composeCommand(
            action: "logs --tail \(lineCount)",
            project: project
        )
        return try await target.client.executeRemoteShellCommand(command, timeout: 25)
    }

    func streamComposeLogs(
        project: DockerComposeProject,
        tail: Int,
        target: ShellTarget
    ) async throws -> AsyncThrowingStream<String, Error> {
        let lineCount = max(1, min(tail, 5000))
        let command = try composeCommand(
            action: "logs --tail \(lineCount) -f",
            project: project
        )
        return try await target.client.streamRemoteShellCommand(command)
    }

    func composeUp(project: DockerComposeProject, target: ShellTarget) async throws {
        let command = try composeCommand(action: "up -d", project: project)
        _ = try await target.client.executeRemoteShellCommand(command, timeout: 30)
    }

    func composeDown(project: DockerComposeProject, target: ShellTarget) async throws {
        let command = try composeCommand(action: "down", project: project)
        _ = try await target.client.executeRemoteShellCommand(command, timeout: 30)
    }

    func composeRestart(project: DockerComposeProject, target: ShellTarget) async throws {
        let command = try composeCommand(action: "restart", project: project)
        _ = try await target.client.executeRemoteShellCommand(command, timeout: 30)
    }

    private func runCommand(
        _ command: String,
        on target: ShellTarget,
        timeout: TimeInterval
    ) async -> Result<String, Error> {
        do {
            let output = try await target.client.executeRemoteShellCommand(command, timeout: timeout)
            return .success(output)
        } catch {
            return .failure(error)
        }
    }

    private func parseDockerVersion(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DockerVersionPayload.self, from: data)
        else {
            return nil
        }

        return payload.server?.version ?? payload.client?.version
    }

    private func parseDockerVersionFallback(_ output: String) -> String? {
        output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.localizedCaseInsensitiveContains("Version:") else { return nil }
                return trimmed.components(separatedBy: "Version:").last?.trimmingCharacters(in: .whitespaces)
            }
            .first
    }

    private func parseComposeVersionFallback(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "v", options: [.backwards]) {
            return String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private func parseContainers(_ output: String) -> [DockerContainer] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty,
                      let data = text.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(DockerPSLine.self, from: data),
                      let id = decoded.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty
                else {
                    return nil
                }

                let labels = parseDockerLabels(decoded.labels)
                return DockerContainer(
                    id: id,
                    name: decoded.names?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id,
                    image: decoded.image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    command: decoded.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: decoded.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    state: decoded.state?.trimmingCharacters(in: .whitespacesAndNewlines),
                    ports: decoded.ports?.trimmingCharacters(in: .whitespacesAndNewlines),
                    createdAt: decoded.createdAt?.trimmingCharacters(in: .whitespacesAndNewlines),
                    runningFor: decoded.runningFor?.trimmingCharacters(in: .whitespacesAndNewlines),
                    composeProject: labels["com.docker.compose.project"],
                    composeService: labels["com.docker.compose.service"],
                    labels: labels
                )
            }
    }

    private func parseImages(_ output: String) -> [DockerImage] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty,
                      let data = text.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(DockerImageLine.self, from: data),
                      let id = decoded.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty
                else {
                    return nil
                }

                return DockerImage(
                    repository: decoded.repository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<none>",
                    tag: decoded.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<none>",
                    imageID: id,
                    digest: decoded.digest?.trimmingCharacters(in: .whitespacesAndNewlines),
                    createdSince: decoded.createdSince?.trimmingCharacters(in: .whitespacesAndNewlines),
                    createdAt: decoded.createdAt?.trimmingCharacters(in: .whitespacesAndNewlines),
                    size: decoded.size?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private func parseContainerDetails(_ output: String, fallbackID: String) throws -> DockerContainerDetails {
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([DockerInspectContainer].self, from: data),
              let container = decoded.first
        else {
            throw SSHError.connectionFailed(tr("Unable to read container details"))
        }

        let labels = container.config?.labels ?? [:]
        let ports = parseInspectPorts(container.networkSettings?.ports)
        let mounts = parseInspectMounts(container.mounts)
        let networks = container.networkSettings?.networks?.keys.sorted() ?? []
        let command = container.command?.joined(separator: " ")
            ?? container.config?.cmd?.joined(separator: " ")
        let entrypoint = container.config?.entrypoint?.joined(separator: " ")

        return DockerContainerDetails(
            id: container.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackID,
            name: container.name?.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines)) ?? fallbackID,
            image: container.config?.image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? container.image ?? "",
            command: command?.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: container.created?.trimmingCharacters(in: .whitespacesAndNewlines),
            status: container.state?.status?.trimmingCharacters(in: .whitespacesAndNewlines),
            restartCount: container.state?.restartCount,
            workingDir: normalizedOptionalPath(container.config?.workingDir),
            entrypoint: normalizedOptionalPath(entrypoint),
            ports: ports,
            mounts: mounts,
            networks: networks,
            labels: labels
        )
    }

    private func parseInspectPorts(_ ports: [String: [InspectPortBinding]?]?) -> [String] {
        guard let ports else { return [] }
        return ports.keys.sorted().map { containerPort in
            let bindings = ports[containerPort] ?? nil
            guard let bindings, !bindings.isEmpty else {
                return containerPort
            }
            let hosts = bindings.map { binding in
                let hostIP = binding.hostIP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hostPort = binding.hostPort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if hostIP.isEmpty {
                    return hostPort
                }
                return "\(hostIP):\(hostPort)"
            }
            .filter { !$0.isEmpty }
            return hosts.isEmpty ? containerPort : "\(hosts.joined(separator: ", ")) -> \(containerPort)"
        }
    }

    private func parseInspectMounts(_ mounts: [InspectMount]?) -> [String] {
        guard let mounts else { return [] }
        return mounts.compactMap { mount in
            guard let source = normalizedOptionalPath(mount.source),
                  let destination = normalizedOptionalPath(mount.destination)
            else {
                return nil
            }
            let type = normalizedOptionalPath(mount.type) ?? "bind"
            let suffix = mount.readWrite == false ? " (ro)" : ""
            return "\(type): \(source) -> \(destination)\(suffix)"
        }
    }

    private func parseDockerLabels(_ rawValue: String?) -> [String: String] {
        guard let rawValue, !rawValue.isEmpty else { return [:] }
        return rawValue
            .split(separator: ",")
            .reduce(into: [String: String]()) { result, entry in
                let pieces = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { return }
                result[pieces[0]] = pieces[1]
            }
    }

    private func parseComposeProjectsJSON(_ output: String) -> [DockerComposeProject]? {
        guard let data = output.data(using: .utf8) else { return nil }

        if let decodedArray = try? JSONDecoder().decode([ComposePSLine].self, from: data) {
            return decodedArray.compactMap(makeComposeProject)
        }

        if let decodedSingle = try? JSONDecoder().decode(ComposePSLine.self, from: data) {
            return [decodedSingle].compactMap(makeComposeProject)
        }

        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        let decoded = lines.compactMap { line -> ComposePSLine? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ComposePSLine.self, from: data)
        }
        return decoded.isEmpty ? nil : decoded.compactMap(makeComposeProject)
    }

    private func parseComposeProjectsText(_ output: String) -> [DockerComposeProject] {
        let rows = output
            .split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard rows.count > 1 else { return [] }
        let dataRows = rows.dropFirst().filter { !$0.lowercased().hasPrefix("name") }

        return dataRows.compactMap { row in
            let columns = row
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            guard let name = columns.first, !name.isEmpty else { return nil }
            let status = columns.dropFirst().first
            return DockerComposeProject(
                name: name,
                status: status,
                configFiles: [],
                workingDir: nil,
                serviceCount: nil
            )
        }
    }

    private func makeComposeProject(_ line: ComposePSLine) -> DockerComposeProject? {
        guard let name = line.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return nil
        }

        let configFiles = splitComposePaths(line.configFiles)
        let workingDir = normalizedOptionalPath(line.workingDir) ?? normalizedOptionalPath(line.projectDirectory)

        return DockerComposeProject(
            name: name,
            status: line.status?.trimmingCharacters(in: .whitespacesAndNewlines),
            configFiles: configFiles,
            workingDir: workingDir,
            serviceCount: line.serviceCount
        )
    }

    private func splitComposePaths(_ rawValue: String?) -> [String] {
        guard let rawValue else { return [] }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return normalized
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedOptionalPath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func composeCommand(action: String, project: DockerComposeProject) throws -> String {
        if let workingDir = project.workingDir {
            return "cd \(quoteShellArgument(workingDir)) && docker compose \(action) 2>&1"
        }

        if let composeFile = project.configFiles.first {
            return "docker compose -f \(quoteShellArgument(composeFile)) \(action) 2>&1"
        }

        throw SSHError.connectionFailed(tr("Unable to determine the Compose working directory for this project"))
    }

    private func classifyDockerIssue(_ message: String) -> DockerEnvironmentIssue {
        let lowercased = message.lowercased()
        if lowercased.contains("not connected") {
            return .sshDisconnected
        }
        if lowercased.contains("command not found") || lowercased.contains("executable file not found") {
            return .dockerNotInstalled
        }
        if lowercased.contains("cannot connect to the docker daemon") {
            return .daemonUnavailable
        }
        if lowercased.contains("got permission denied while trying to connect") || lowercased.contains("permission denied") {
            return .permissionDenied
        }
        return .commandFailed(message)
    }

    private func classifyComposeIssue(_ message: String) -> DockerEnvironmentIssue {
        let lowercased = message.lowercased()
        if lowercased.contains("docker: 'compose' is not a docker command")
            || lowercased.contains("unknown command \"compose\"")
            || lowercased.contains("command not found")
        {
            return .composeUnavailable
        }
        if lowercased.contains("unknown flag") || lowercased.contains("unknown shorthand flag") {
            return .composeUnsupported
        }
        if lowercased.contains("permission denied") {
            return .permissionDenied
        }
        return .commandFailed(message)
    }

    private func isDockerFormatUnsupported(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("unknown flag: --format")
            || lowercased.contains("template parsing error")
            || lowercased.contains("function \"json\" not defined")
    }

    private func isComposeShortUnsupported(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("unknown flag: --short") || lowercased.contains("unknown shorthand flag")
    }

    private func quoteShellArgument(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
