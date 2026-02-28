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
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains(where: { $0.hasPrefix("ControlPath=/tmp/") }))
        #expect(args.contains("-i"))
        #expect(args.contains("/Users/demo/.ssh/id_ed25519"))
        #expect(args.contains("PreferredAuthentications=publickey"))
        #expect(args.contains("deploy@10.0.0.2"))
    }

    @Test
    func buildsSSHArgumentsWithoutForcedTTY() {
        let host = Host(
            name: "prod",
            address: "10.0.0.2",
            port: 2202,
            username: "deploy",
            auth: HostAuth(method: .privateKey, keyReference: "/Users/demo/.ssh/id_ed25519"),
            policies: HostPolicies(keepAliveSeconds: 40, connectTimeoutSeconds: 12, terminalProfileID: "default")
        )

        let args = SystemSFTPClient.makeSSHArguments(for: host)

        #expect(!args.contains("-tt"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ControlMaster=auto"))
    }

    @Test
    func buildsPasswordAuthArgumentsWithSinglePromptLimit() {
        let host = Host(
            name: "remote",
            address: "47.100.100.215",
            port: 22,
            username: "root",
            auth: HostAuth(method: .password, passwordReference: "pw-ref"),
            policies: HostPolicies(keepAliveSeconds: 15, connectTimeoutSeconds: 8, terminalProfileID: "default")
        )

        let sftpArgs = SystemSFTPClient.makeSFTPArguments(for: host)
        let sshArgs = SystemSFTPClient.makeSSHArguments(for: host)

        #expect(sftpArgs.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(sftpArgs.contains("NumberOfPasswordPrompts=1"))
        #expect(sshArgs.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(sshArgs.contains("NumberOfPasswordPrompts=1"))
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
    func parsesLongListOutputWithAbsolutePathsAndSkipsDotEntries() {
        let output = """
        drwxr-xr-x    3 root root      96 Jan 12 14:33 /home/.
        drwxr-xr-x   24 root root    4096 Jan 12 14:33 /home/..
        drwx------    4 root root     128 Jan 13 09:01 /home/lighting
        """

        let entries = SystemSFTPClient.parseLongListOutput(output, parentPath: "/home")
        #expect(entries.count == 1)
        #expect(entries[0].name == "lighting")
        #expect(entries[0].path == "/home/lighting")
        #expect(entries[0].isDirectory)
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

    @Test
    func parsesNameOnlyListOutputFallback() {
        let output = """
        bin/
        etc/
        README.txt
        """

        let entries = SystemSFTPClient.parseNameOnlyListOutput(output, parentPath: "/")
        #expect(entries.count == 3)
        #expect(entries.contains(where: { $0.path == "/bin" && $0.isDirectory }))
        #expect(entries.contains(where: { $0.path == "/etc" && $0.isDirectory }))
        #expect(entries.contains(where: { $0.path == "/README.txt" && !$0.isDirectory }))
    }

    @Test
    func parsesNameOnlyOutputWithAbsolutePathsAndSkipsDotEntries() {
        let output = """
        /home/.
        /home/..
        /home/lighting/
        """

        let entries = SystemSFTPClient.parseNameOnlyListOutput(output, parentPath: "/home")
        #expect(entries.count == 1)
        #expect(entries[0].name == "lighting")
        #expect(entries[0].path == "/home/lighting")
        #expect(entries[0].isDirectory)
    }

    @Test
    func detectsTransientConnectionFailureMessages() {
        #expect(SystemSFTPClient.isTransientConnectionFailureMessage("Connection failed: Connection closed"))
        #expect(SystemSFTPClient.isTransientConnectionFailureMessage("mux_client_request_session: read from master failed: Broken pipe"))
        #expect(SystemSFTPClient.isTransientConnectionFailureMessage("control socket connect(/tmp/ctl): Connection refused"))
    }

    @Test
    func ignoresNonTransientConnectionFailureMessages() {
        #expect(!SystemSFTPClient.isTransientConnectionFailureMessage("Permission denied (publickey,password)."))
        #expect(!SystemSFTPClient.isTransientConnectionFailureMessage("No such file or directory"))
    }

    @Test
    func diagnosticsRetentionDeletesOnlyExpiredFiles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justInsideRetention = now.addingTimeInterval(-Double(14 * 24 * 60 * 60 - 60))
        let justOutsideRetention = now.addingTimeInterval(-Double(14 * 24 * 60 * 60 + 60))

        #expect(!SystemSFTPClient.shouldDeleteDiagnosticsFile(referenceDate: justInsideRetention, now: now, retentionDays: 14))
        #expect(SystemSFTPClient.shouldDeleteDiagnosticsFile(referenceDate: justOutsideRetention, now: now, retentionDays: 14))
    }
}
