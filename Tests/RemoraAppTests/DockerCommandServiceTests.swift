import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct DockerCommandServiceTests {
    actor StubSFTPClient: SFTPClientProtocol {
        enum StubError: Error {
            case failure(String)
        }

        var responses: [String: Result<String, Error>]

        init(responses: [String: Result<String, Error>]) {
            self.responses = responses
        }

        func list(path: String) async throws -> [RemoteFileEntry] {
            _ = path
            return []
        }

        func download(path: String) async throws -> Data {
            _ = path
            return Data()
        }

        func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws {
            _ = path
            _ = localFileURL
            _ = progress
        }

        func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String {
            _ = timeout
            guard let result = responses[command] else {
                throw StubError.failure("missing response for \(command)")
            }
            return try result.get()
        }

        func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> {
            let value = try await executeRemoteShellCommand(command, timeout: nil)
            return AsyncThrowingStream { continuation in
                continuation.yield(value)
                continuation.finish()
            }
        }

        func upload(data: Data, to path: String) async throws {
            _ = data
            _ = path
        }

        func rename(from: String, to: String) async throws {
            _ = from
            _ = to
        }

        func mkdir(path: String) async throws {
            _ = path
        }

        func remove(path: String) async throws {
            _ = path
        }
    }

    private func makeTarget(
        responses: [String: Result<String, Error>]
    ) -> DockerCommandService.ShellTarget {
        let host = Host(
            name: "docker-host",
            address: "127.0.0.1",
            username: "root",
            auth: HostAuth(method: .agent)
        )
        return DockerCommandService.ShellTarget(
            host: host,
            client: StubSFTPClient(responses: responses)
        )
    }

    @Test
    func checkEnvironmentReadsDockerAndComposeVersions() async throws {
        let service = DockerCommandService()
        let target = makeTarget(
            responses: [
                "docker version --format '{{json .}}'": .success(#"{"Client":{"Version":"27.0.1"},"Server":{"Version":"27.1.0"}}"#),
                "docker compose version --short": .success("2.29.1\n"),
            ]
        )

        let environment = try await service.checkEnvironment(target: target)

        #expect(environment.dockerAvailable)
        #expect(environment.composeAvailable)
        #expect(environment.dockerVersion == "27.1.0")
        #expect(environment.composeVersion == "2.29.1")
    }

    @Test
    func checkEnvironmentFallsBackWhenFormatFlagIsUnsupported() async throws {
        let service = DockerCommandService()
        let target = makeTarget(
            responses: [
                "docker version --format '{{json .}}'": .failure(SSHError.connectionFailed("unknown flag: --format")),
                "docker version": .success("Client:\n Version:           26.1.0\nServer:\n Version:           26.1.3\n"),
                "docker compose version --short": .failure(SSHError.connectionFailed("docker: 'compose' is not a docker command")),
            ]
        )

        let environment = try await service.checkEnvironment(target: target)

        #expect(environment.dockerAvailable)
        #expect(environment.dockerVersion == "26.1.0")
        #expect(environment.composeAvailable == false)
        #expect(environment.composeIssue == .composeUnavailable)
    }

    @Test
    func listContainersParsesJsonLinesAndSkipsInvalidRows() async throws {
        let service = DockerCommandService()
        let validLine = #"{"ID":"abc123","Names":"web","Image":"nginx:latest","Command":"\"nginx -g 'daemon off;'\"","Status":"Up 2 hours","State":"running","Ports":"80/tcp","RunningFor":"2 hours","Labels":"com.docker.compose.project=demo,com.docker.compose.service=web"}"#
        let target = makeTarget(
            responses: [
                "docker ps -a --format '{{json .}}'": .success(validLine + "\ninvalid-json\n"),
            ]
        )

        let containers = try await service.listContainers(target: target)

        #expect(containers.count == 1)
        #expect(containers.first?.id == "abc123")
        #expect(containers.first?.composeProject == "demo")
        #expect(containers.first?.composeService == "web")
        #expect(containers.first?.isRunning == true)
    }

    @Test
    func listComposeProjectsParsesJsonArrayOutput() async throws {
        let service = DockerCommandService()
        let output = #"[{"Name":"demo","Status":"running(2)","ConfigFiles":"/srv/demo/compose.yml","WorkingDir":"/srv/demo","ServiceCount":2}]"#
        let target = makeTarget(
            responses: [
                "docker compose ls --format json": .success(output),
            ]
        )

        let projects = try await service.listComposeProjects(target: target)

        #expect(projects.count == 1)
        #expect(projects.first?.name == "demo")
        #expect(projects.first?.workingDir == "/srv/demo")
        #expect(projects.first?.configFiles == ["/srv/demo/compose.yml"])
        #expect(projects.first?.canRunCommands == true)
    }

    @Test
    func listVolumesParsesJsonLines() async throws {
        let service = DockerCommandService()
        let output = #"{"Name":"redis_data","Driver":"local","Scope":"local","Mountpoint":"/var/lib/docker/volumes/redis_data/_data","Labels":"com.docker.compose.project=redis"}"#
        let target = makeTarget(
            responses: [
                "docker volume ls --format '{{json .}}'": .success(output),
            ]
        )

        let volumes = try await service.listVolumes(target: target)

        #expect(volumes.count == 1)
        #expect(volumes.first?.name == "redis_data")
        #expect(volumes.first?.driver == "local")
        #expect(volumes.first?.labels["com.docker.compose.project"] == "redis")
    }

    @Test
    func listNetworksParsesInspectOutput() async throws {
        let service = DockerCommandService()
        let command = "ids=$(docker network ls -q); if [ -n \"$ids\" ]; then docker network inspect $ids; fi"
        let output = #"[{"Id":"abcdef1234567890","Name":"bridge","Driver":"bridge","Scope":"local","Labels":{"kind":"default"},"IPAM":{"Config":[{"Subnet":"172.17.0.0/16","Gateway":"172.17.0.1"}]}}]"#
        let target = makeTarget(
            responses: [
                command: .success(output),
            ]
        )

        let networks = try await service.listNetworks(target: target)

        #expect(networks.count == 1)
        #expect(networks.first?.name == "bridge")
        #expect(networks.first?.subnet == "172.17.0.0/16")
        #expect(networks.first?.gateway == "172.17.0.1")
    }

    @Test
    func containerStatsParsesJsonLines() async throws {
        let service = DockerCommandService()
        let output = #"{"Container":"abc123","Name":"redis","CPUPerc":"0.42%","MemUsage":"4.8MiB / 1.9GiB","MemPerc":"0.25%","NetIO":"1.2kB / 3.4kB","BlockIO":"0B / 31kB","PIDs":"6"}"#
        let target = makeTarget(
            responses: [
                "docker stats --no-stream --format '{{json .}}'": .success(output),
            ]
        )

        let stats = try await service.containerStats(target: target)

        #expect(stats.count == 1)
        #expect(stats.first?.name == "redis")
        #expect(stats.first?.cpuPercent == 0.42)
        #expect(stats.first?.memoryUsage == "4.8MiB")
        #expect(stats.first?.memoryPercent == 0.25)
    }

    @Test
    func containerLogsRedirectsStderrIntoStdout() async throws {
        let service = DockerCommandService()
        let target = makeTarget(
            responses: [
                "docker logs --tail 120 'abc123' 2>&1": .success("stderr-and-stdout\n"),
            ]
        )

        let output = try await service.containerLogs(containerID: "abc123", tail: 120, target: target)

        #expect(output == "stderr-and-stdout\n")
    }
}
