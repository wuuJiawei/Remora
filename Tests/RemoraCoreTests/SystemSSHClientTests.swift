import Testing
import Foundation
@testable import RemoraCore

struct SystemSSHClientTests {
    @Test
    func buildsArgumentsForPrivateKeyAuth() {
        let host = Host(
            name: "prod",
            address: "10.0.0.2",
            port: 2222,
            username: "deploy",
            auth: HostAuth(method: .privateKey, keyReference: "/Users/demo/.ssh/id_ed25519"),
            policies: HostPolicies(keepAliveSeconds: 30, connectTimeoutSeconds: 8, terminalProfileID: "default")
        )

        let args = ProcessSSHShellSession.makeSSHArguments(for: host)

        #expect(args.contains("-tt"))
        #expect(args.contains("-p"))
        #expect(args.contains("2222"))
        #expect(args.contains("ConnectTimeout=8"))
        #expect(args.contains("ServerAliveInterval=30"))
        #expect(args.contains("ServerAliveCountMax=3"))
        #expect(args.contains("StrictHostKeyChecking=ask"))
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains(where: { $0.hasPrefix("ControlPath=/tmp/") }))
        #expect(args.contains("-i"))
        #expect(args.contains("/Users/demo/.ssh/id_ed25519"))
        #expect(args.contains("deploy@10.0.0.2"))
    }

    @Test
    func buildsArgumentsForAgentAuth() {
        let host = Host(
            name: "staging",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent),
            policies: HostPolicies(keepAliveSeconds: 3, connectTimeoutSeconds: 0, terminalProfileID: "default")
        )

        let args = ProcessSSHShellSession.makeSSHArguments(for: host)

        #expect(args.contains("ConnectTimeout=1"))
        #expect(args.contains("ServerAliveInterval=5"))
        #expect(args.contains("PreferredAuthentications=publickey"))
    }

    @Test
    func prefersScriptWrapperWhenAvailable() {
        let host = Host(
            name: "staging",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )

        let launch = ProcessSSHShellSession.makeLaunchConfiguration(for: host)

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            #expect(launch.executablePath == "/usr/bin/script")
            #expect(launch.arguments.starts(with: ["-q", "/dev/null", "/usr/bin/ssh"]))
        } else {
            #expect(launch.executablePath == "/usr/bin/ssh")
        }
    }
}
