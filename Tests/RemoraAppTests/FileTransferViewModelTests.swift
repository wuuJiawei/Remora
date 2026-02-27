import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

@MainActor
struct FileTransferViewModelTests {
    @Test
    func uploadThenDownloadRoundTrip() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let localFile = tempRoot.appendingPathComponent("hello.txt")
        try Data("hello-remora".utf8).write(to: localFile)

        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 2
        )

        vm.refreshLocalEntries()
        await vm.refreshRemoteEntries()

        guard let source = vm.localEntries.first(where: { $0.name == "hello.txt" }) else {
            Issue.record("Local fixture file not found")
            return
        }

        vm.enqueueUpload(localEntry: source)
        try await waitForSuccess(in: vm, transferName: "hello.txt", successCount: 1)

        await vm.refreshRemoteEntries()
        guard let remote = vm.remoteEntries.first(where: { $0.name == "hello.txt" }) else {
            Issue.record("Uploaded file missing on remote")
            return
        }

        try FileManager.default.removeItem(at: localFile)
        vm.refreshLocalEntries()

        vm.enqueueDownload(remoteEntry: remote)
        try await waitForSuccess(in: vm, transferName: "hello.txt", successCount: 2)

        let downloadedData = try Data(contentsOf: localFile)
        #expect(String(decoding: downloadedData, as: UTF8.self) == "hello-remora")
    }

    @Test
    func moveAndDeleteRemoteEntries() async throws {
        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 2
        )

        await vm.refreshRemoteEntries()
        let hasReadme = vm.remoteEntries.contains(where: { $0.path == "/README.txt" })
        #expect(hasReadme)

        vm.moveRemoteEntries(paths: ["/README.txt"], toDirectory: "/docs")
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            let rootHasReadme = vm.remoteEntries.contains(where: { $0.path == "/README.txt" })
            return rootHasReadme == false
        }

        vm.navigateRemote(to: "/docs")
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/docs/README.txt" })
        }

        vm.deleteRemoteEntries(paths: ["/docs/README.txt"])
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/docs/README.txt" }) == false
        }
    }

    @Test
    func recursiveUploadFromDirectoryPreservesRelativePath() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-upload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let localFolder = tempRoot.appendingPathComponent("bundle")
        let nestedFolder = localFolder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        let topFile = localFolder.appendingPathComponent("a.txt")
        let nestedFile = nestedFolder.appendingPathComponent("b.txt")
        try Data("top".utf8).write(to: topFile)
        try Data("nested".utf8).write(to: nestedFile)

        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )

        vm.enqueueUpload(localFileURLs: [localFolder], toRemoteDirectory: "/")
        try await waitUntil(timeoutLoops: 80, intervalMS: 50) {
            let terminalStateCount = vm.transferQueue.filter {
                $0.status == .success || $0.status == .failed
            }.count
            return terminalStateCount >= 2
        }
        let failures = vm.transferQueue.filter { $0.status == .failed }
        #expect(failures.isEmpty)
        #expect(vm.transferQueue.filter { $0.status == .success }.count >= 2)

        vm.navigateRemote(to: "/bundle")
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/bundle/a.txt" })
        }

        vm.navigateRemote(to: "/bundle/nested")
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/bundle/nested/b.txt" })
        }
    }

    @Test
    func multiDownloadUpdatesTaskAndOverallProgress() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-download-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let seededLocalFile = tempRoot.appendingPathComponent("seed.txt")
        try Data("seed-data".utf8).write(to: seededLocalFile)

        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 2
        )

        vm.refreshLocalEntries()
        guard let seedEntry = vm.localEntries.first(where: { $0.name == "seed.txt" }) else {
            Issue.record("Seed local file not found.")
            return
        }

        vm.enqueueUpload(localEntry: seedEntry)
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.transferQueue.contains(where: { $0.direction == .upload && $0.status == .success })
        }

        await vm.refreshRemoteEntries()
        let downloadTargets = vm.remoteEntries.filter { !$0.isDirectory }
        #expect(downloadTargets.count >= 2)

        try? FileManager.default.removeItem(at: seededLocalFile)
        vm.refreshLocalEntries()

        for target in downloadTargets {
            vm.enqueueDownload(remoteEntry: target)
        }

        let expectedSuccessfulTransfers = 1 + downloadTargets.count
        try await waitUntil(timeoutLoops: 80, intervalMS: 50) {
            vm.transferQueue.filter { $0.status == .success }.count >= expectedSuccessfulTransfers
        }

        let downloadItems = vm.transferQueue.filter { $0.direction == .download }
        #expect(downloadItems.count == downloadTargets.count)
        #expect(downloadItems.allSatisfy { $0.totalBytes != nil })
        #expect(downloadItems.allSatisfy { $0.bytesTransferred == $0.totalBytes })
        #expect(vm.overallTransferProgress == 1)
    }

    @Test
    func conflictStrategyRenameCreatesAlternateDownloadPath() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-conflict-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let existingReadme = tempRoot.appendingPathComponent("README.txt")
        try Data("existing".utf8).write(to: existingReadme)

        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            localDirectoryURL: tempRoot
        )
        vm.conflictStrategy = .rename

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.transferQueue.contains(where: { $0.direction == .download && $0.status == .success })
        }

        let renamedPath = tempRoot.appendingPathComponent("README (1).txt").path
        #expect(FileManager.default.fileExists(atPath: renamedPath))
    }

    @Test
    func skippedTransferCanBeRetriedAfterStrategyChange() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-conflict-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let existingReadme = tempRoot.appendingPathComponent("README.txt")
        try Data("existing".utf8).write(to: existingReadme)

        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            localDirectoryURL: tempRoot
        )
        vm.conflictStrategy = .skip

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.transferQueue.contains(where: { $0.direction == .download && $0.status == .skipped })
        }

        guard let skippedItem = vm.transferQueue.first(where: { $0.direction == .download && $0.status == .skipped }) else {
            Issue.record("Expected skipped download transfer item.")
            return
        }

        vm.conflictStrategy = .overwrite
        vm.retryTransfer(itemID: skippedItem.id)
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.transferQueue.contains(where: { $0.id == skippedItem.id && $0.status == .success })
        }
    }

    @Test
    func contextActionsSupportRenameCopyPasteAndDelete() async throws {
        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        await vm.refreshRemoteEntries()
        #expect(vm.remoteEntries.contains(where: { $0.path == "/README.txt" }))

        vm.performContextAction(.rename(path: "/README.txt", newName: "README-renamed.txt"))
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/README-renamed.txt" })
        }

        vm.performContextAction(.copy(paths: ["/README-renamed.txt"]))
        #expect(vm.canPaste(into: "/logs"))
        vm.performContextAction(.paste(destinationDirectory: "/logs"))
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.navigateRemote(to: "/logs")
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/logs/README-renamed.txt" })
        }

        vm.performContextAction(.delete(paths: ["/logs/README-renamed.txt"]))
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/logs/README-renamed.txt" }) == false
        }
    }

    @Test
    func textDocumentRoundTripSupportsLoadAndSave() async throws {
        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )

        let loaded = try await vm.loadTextDocument(path: "/README.txt")
        #expect(loaded.text.contains("Remora"))
        #expect(loaded.encoding == "UTF-8")
        #expect(!loaded.isReadOnly)

        let modified = loaded.text + "\nupdated"
        let savedModifiedAt = try await vm.saveTextDocument(
            path: "/README.txt",
            text: modified,
            expectedModifiedAt: loaded.modifiedAt
        )
        #expect(savedModifiedAt != nil)

        let reloaded = try await vm.loadTextDocument(path: "/README.txt")
        #expect(reloaded.text.contains("updated"))
    }

    @Test
    func remotePropertiesRoundTripSupportsLoadAndSave() async throws {
        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )

        var attrs = try await vm.loadRemoteAttributes(path: "/README.txt")
        attrs.permissions = 0o600
        attrs.owner = "owner1"
        attrs.group = "group1"
        try await vm.saveRemoteAttributes(path: "/README.txt", attributes: attrs)

        let updated = try await vm.loadRemoteAttributes(path: "/README.txt")
        #expect(updated.permissions == 0o600)
        #expect(updated.owner == "owner1")
        #expect(updated.group == "group1")
    }

    @Test
    func bindSFTPClientSwitchesRemoteSourceAndResetsTransientState() async throws {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        await vm.refreshRemoteEntries()
        #expect(vm.remoteEntries.contains(where: { $0.path == "/README.txt" }))

        vm.performContextAction(.copy(paths: ["/README.txt"]))
        vm.enqueueDownload(paths: ["/README.txt"])
        #expect(vm.remoteClipboard != nil)
        #expect(!vm.transferQueue.isEmpty)

        let nextClient = MockSFTPClient()
        try await nextClient.remove(path: "/README.txt")
        try await nextClient.upload(data: Data("next".utf8), to: "/next.txt")

        vm.bindSFTPClient(nextClient, initialRemoteDirectory: "/")

        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/next.txt" })
        }

        #expect(vm.remoteEntries.contains(where: { $0.path == "/next.txt" }))
        #expect(!vm.remoteEntries.contains(where: { $0.path == "/README.txt" }))
        #expect(vm.remoteClipboard == nil)
        #expect(vm.transferQueue.isEmpty)
    }

    private func waitForSuccess(in vm: FileTransferViewModel, transferName: String, successCount: Int) async throws {
        for _ in 0 ..< 40 {
            let success = vm.transferQueue.filter { $0.name == transferName && $0.status == .success }.count
            if success >= successCount {
                return
            }
            if let failed = vm.transferQueue.first(where: { $0.name == transferName && $0.status == .failed }) {
                throw NSError(domain: "FileTransferViewModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: failed.message ?? "transfer failed"])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "FileTransferViewModelTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "timeout waiting transfer success"])
    }

    private func waitUntil(
        timeoutLoops: Int,
        intervalMS: UInt64,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0 ..< timeoutLoops {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(intervalMS))
        }
        throw NSError(domain: "FileTransferViewModelTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "timeout waiting condition"])
    }
}
