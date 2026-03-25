import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

@Suite(.serialized)
@MainActor
struct TerminalDirectorySyncBridgeTests {
    @Test
    func localRuntimeDoesNotDriveRemoteFileManagerDirectory() async {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectLocalShell()
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected")
        }
        #expect(connected)
        guard connected else { return }

        fileTransfer.isTerminalDirectorySyncEnabled = true
        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)
        runtime.changeDirectory(to: "/tmp")

        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(
            fileTransfer.remoteDirectoryPath == "/",
            "Local terminal sessions should not drive remote file manager path."
        )
        runtime.disconnect()
    }

    @Test
    func fileManagerDirectoryChangeDoesNotPushToRuntime() async {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        fileTransfer.isTerminalDirectorySyncEnabled = true
        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)

        fileTransfer.navigateRemote(to: "/logs")
        try? await Task.sleep(nanoseconds: 400_000_000)

        #expect(
            runtime.workingDirectory != "/logs",
            "File manager directory should not drive runtime directory."
        )
        runtime.disconnect()
    }

    @Test
    func runtimeDirectoryChangePushesToFileManager() async {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        fileTransfer.isTerminalDirectorySyncEnabled = true
        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)

        runtime.changeDirectory(to: "/logs")

        let synced = await waitUntil(timeout: 2.0) {
            fileTransfer.remoteDirectoryPath == "/logs"
        }
        #expect(synced, "Terminal runtime directory should sync back to file manager.")
        runtime.disconnect()
    }

    @Test
    func runtimeToFileManagerSyncDoesNotIssueExtraCdCommand() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(
                    recorder: recorder,
                    initialDirectory: "/",
                    workingDirectoryEventStyle: .osc7OnPrompt
                )
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        fileTransfer.isTerminalDirectorySyncEnabled = true
        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)
        await recorder.reset()

        runtime.changeDirectory(to: "/logs")

        let synced = await waitUntil(timeout: 2.0) {
            fileTransfer.remoteDirectoryPath == "/logs"
        }
        #expect(synced, "Runtime path should propagate to file manager.")
        guard synced else { return }

        try? await Task.sleep(nanoseconds: 400_000_000)
        let cdCommands = await recorder.commands.filter { $0.hasPrefix("cd ") }
        #expect(cdCommands.count == 1, "Bridge should not emit extra cd commands. observed commands: \(cdCommands)")
        runtime.disconnect()
    }

    @Test
    func disabledSyncTogglePreventsRuntimeToFileManagerSyncInSSH() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(
                    recorder: recorder,
                    initialDirectory: "/",
                    workingDirectoryEventStyle: .osc7OnPrompt
                )
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)
        await recorder.reset()

        fileTransfer.navigateRemote(to: "/logs")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(runtime.workingDirectory != "/logs", "File manager should never drive runtime directory.")

        runtime.changeDirectory(to: "/tmp")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(fileTransfer.remoteDirectoryPath == "/logs", "Runtime updates should not drive file manager while sync is disabled.")

        let cdCommands = await recorder.commands.filter { $0.hasPrefix("cd ") }
        #expect(cdCommands.count == 1, "Only explicit runtime cd should be recorded when sync is off.")
        runtime.disconnect()
    }

    @Test
    func enablingSyncAfterBindingAlignsFileManagerToCurrentRuntimeDirectory() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(
                    recorder: recorder,
                    initialDirectory: "/opt/service",
                    pwdOutputStyle: .ansiWrapped,
                    workingDirectoryEventStyle: .osc7OnPrompt
                )
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)
        let stillRoot = await waitUntil(timeout: 2.0) {
            fileTransfer.remoteDirectoryPath == "/"
        }
        #expect(stillRoot)

        let changed = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/opt/service"
        }
        #expect(changed)
        guard changed else { return }

        fileTransfer.isTerminalDirectorySyncEnabled = true

        let synced = await waitUntil(timeout: 2.0) {
            fileTransfer.remoteDirectoryPath == "/opt/service"
        }
        #expect(synced, "Turning on sync should align file manager to current runtime directory.")
        runtime.disconnect()
    }

    @Test
    func enablingSyncDoesNotIssuePwdWhenRuntimeAlreadyKnowsDirectory() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(
                    recorder: recorder,
                    initialDirectory: "/opt/service",
                    pwdOutputStyle: .ansiWrapped,
                    workingDirectoryEventStyle: .osc7OnPrompt
                )
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        let detected = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/opt/service"
        }
        #expect(detected, "Runtime should know the remote directory before sync is enabled.")
        guard detected else { return }

        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)
        await recorder.reset()

        fileTransfer.isTerminalDirectorySyncEnabled = true

        let synced = await waitUntil(timeout: 2.0) {
            fileTransfer.remoteDirectoryPath == "/opt/service"
        }
        #expect(synced, "Enabling sync should reuse the known runtime directory.")

        try? await Task.sleep(nanoseconds: 400_000_000)
        let pwdCommands = await recorder.commands.filter { $0 == "pwd" }
        #expect(pwdCommands.isEmpty, "Enabling sync should not issue pwd when runtime directory is already known. observed commands: \(pwdCommands)")
        runtime.disconnect()
    }

    @Test
    func typedTerminalDirectoryChangePushesToFileManagerWhenSyncEnabled() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(
                    recorder: recorder,
                    initialDirectory: "/srv/app",
                    workingDirectoryEventStyle: .osc7OnPrompt
                )
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
        let fileTransfer = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        let bridge = TerminalDirectorySyncBridge()

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        bridge.bind(fileTransfer: fileTransfer, runtime: runtime)
        fileTransfer.isTerminalDirectorySyncEnabled = true
        await recorder.reset()

        runtime.sendText("cd '/srv/app/releases'\n")

        let synced = await waitUntil(timeout: 2.0) {
            fileTransfer.remoteDirectoryPath == "/srv/app/releases"
        }
        #expect(synced, "File manager should follow terminal-entered directory changes when sync is enabled.")

        let pwdCommands = await recorder.commands.filter { $0 == "pwd" }
        #expect(pwdCommands.isEmpty, "Terminal-entered directory sync should not rely on pwd probes. observed commands: \(pwdCommands)")
        runtime.disconnect()
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func waitUntilAsync(timeout: TimeInterval, condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }
}
