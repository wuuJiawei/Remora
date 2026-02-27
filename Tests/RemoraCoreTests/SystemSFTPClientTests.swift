import Foundation
import Testing
@testable import RemoraCore

struct SystemSFTPClientTests {
    @Test
    func buildsArgumentsForPrivateKeyAuth() {
        let host = Host(
            name: "prod",
            address: "10.0.0.2",
            port: 2202,
            username: "deploy",
            auth: HostAuth(method: .privateKey, keyReference: "/Users/demo/.ssh/id_ed25519"),
            policies: HostPolicies(keepAliveSeconds: 40, connectTimeoutSeconds: 12, terminalProfileID: "default")
        )

        let args = SystemSFTPClient.makeSFTPArguments(for: host)

        #expect(args.starts(with: ["-q", "-b", "-"]))
        #expect(args.contains("-P"))
        #expect(args.contains("2202"))
        #expect(args.contains("ConnectTimeout=12"))
        #expect(args.contains("ServerAliveInterval=40"))
        #expect(args.contains("StrictHostKeyChecking=ask"))
        #expect(args.contains("-i"))
        #expect(args.contains("/Users/demo/.ssh/id_ed25519"))
        #expect(args.contains("PreferredAuthentications=publickey"))
        #expect(args.contains("deploy@10.0.0.2"))
    }

    @Test
    func parsesLongListOutputWithFilesAndDirectories() {
        let output = """
        drwxr-xr-x    3 deploy deploy      96 Jan 12 14:33 logs
        -rw-r--r--    1 deploy deploy      16 Jan 13 09:01 README.txt
        """

        let now = Date(timeIntervalSince1970: 1_705_000_000)
        let entries = SystemSFTPClient.parseLongListOutput(output, parentPath: "/", now: now)

        #expect(entries.count == 2)
        #expect(entries[0].path == "/logs")
        #expect(entries[0].isDirectory)
        #expect(entries[1].path == "/README.txt")
        #expect(entries[1].size == 16)
        #expect(!entries[1].isDirectory)
    }

    @Test
    func parsesPermissionsAndOwnershipFromLongList() {
        let output = """
        -rw-r-----    1 user1 group2     512 Feb 10 2024 app.conf
        """

        let parsed = SystemSFTPClient.parseLongListEntries(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].name == "app.conf")
        #expect(parsed[0].permissions == 0o640)
        #expect(parsed[0].owner == "user1")
        #expect(parsed[0].group == "group2")
        #expect(parsed[0].size == 512)
    }
}
