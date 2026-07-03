import Testing
@testable import RemoraApp

struct DockerContainerTreeBuilderTests {
    @Test
    func buildContainerTreeGroupsByStateAndComposeProject() {
        let runningComposeContainer = makeContainer(
            id: "running-compose",
            name: "redis",
            state: "running",
            composeProject: "stack",
            composeService: "redis"
        )
        let runningStandalone = makeContainer(
            id: "running-standalone",
            name: "worker",
            state: "running"
        )
        let stoppedComposeContainer = makeContainer(
            id: "stopped-compose",
            name: "db",
            state: "exited",
            composeProject: "stack",
            composeService: "db"
        )

        let tree = DockerContainerTreeBuilder.buildContainerTree(
            containers: [stoppedComposeContainer, runningStandalone, runningComposeContainer],
            composeProjects: [
                DockerComposeProject(
                    name: "stack",
                    status: "running(1)",
                    configFiles: [],
                    workingDir: nil,
                    serviceCount: 2
                )
            ]
        )

        #expect(tree.map(\.title) == [tr("Running"), tr("Stopped")])
        #expect(tree[0].children.map(\.kind) == [.compose, .container])
        #expect(tree[0].children[0].title == "stack")
        #expect(tree[0].children[0].children.map(\.title) == ["redis"])
        #expect(tree[0].children[1].title == "worker")
        #expect(tree[1].children.map(\.kind) == [.compose])
        #expect(tree[1].children[0].children.map(\.title) == ["db"])
    }

    private func makeContainer(
        id: String,
        name: String,
        state: String,
        composeProject: String? = nil,
        composeService: String? = nil
    ) -> DockerContainer {
        DockerContainer(
            id: id,
            name: name,
            image: "\(name):latest",
            command: nil,
            status: state == "running" ? "Up 1 minute" : "Exited",
            state: state,
            ports: nil,
            createdAt: nil,
            runningFor: nil,
            composeProject: composeProject,
            composeService: composeService,
            labels: [:]
        )
    }
}
