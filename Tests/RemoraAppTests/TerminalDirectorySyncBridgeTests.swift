import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

@MainActor
struct TerminalDirectorySyncBridgeTests {
    @Test
    func localRuntimeDoesNotDriveRemoteFileManagerDirectory() async {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
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
    func fileManagerDirectoryChangePushesToRuntime() async {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
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

        let synced = await waitUntil(timeout: 2.0) {
            runtime.workingDirectory == "/logs"
        }
        #expect(synced, "File manager directory should sync to terminal runtime.")
        runtime.disconnect()
    }

    @Test
    func runtimeDirectoryChangePushesToFileManager() async {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
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
    func runtimeToFileManagerSyncDoesNotLoopBackIntoRepeatedCd() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/")
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
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
        #expect(
            cdCommands.count == 1,
            "Bridge should avoid sync loops. observed commands: \(cdCommands)"
        )
        runtime.disconnect()
    }

    @Test
    func disabledSyncTogglePreventsBidirectionalSyncInSSH() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/")
            }
        )
        let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager)
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
        #expect(runtime.workingDirectory != "/logs", "Sync should stay off until toggle enabled.")

        runtime.changeDirectory(to: "/tmp")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(fileTransfer.remoteDirectoryPath == "/logs", "Runtime updates should not drive file manager while sync is disabled.")

        let cdCommands = await recorder.commands.filter { $0.hasPrefix("cd ") }
        #expect(cdCommands.count == 1, "Only explicit runtime cd should be recorded when sync is off.")
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
}
