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
    func downloadSuccessIncludesSavedPathMessage() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-download-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )
        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.transferQueue.contains(where: { $0.direction == .download && $0.status == .success })
        }

        guard let done = vm.transferQueue.first(where: { $0.direction == .download && $0.status == .success }) else {
            Issue.record("Expected successful download transfer.")
            return
        }
        #expect(done.message?.contains("Saved to:") == true)
        #expect(done.message?.contains("README.txt") == true)
        #expect(FileManager.default.fileExists(atPath: done.destinationPath))
    }

    @Test
    func downloadsUseDirectFileOutputPath() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-direct-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = DirectDownloadOnlySFTPClient()
        let vm = FileTransferViewModel(
            sftpClient: client,
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.transferQueue.contains(where: { $0.direction == .download && $0.status == .success })
        }

        let usedDirectPath = await client.usedDirectDownloadPath()
        #expect(usedDirectPath)
    }

    @Test
    func directoryDownloadPreservesNestedStructure() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-directory-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let logsDirectory = vm.remoteEntries.first(where: { $0.path == "/logs" && $0.isDirectory }) else {
            Issue.record("Remote logs directory not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: logsDirectory)
        try await waitUntil(timeoutLoops: 60, intervalMS: 50) {
            vm.transferQueue.contains(where: {
                $0.direction == .download && $0.sourcePath == "/logs" && $0.status == .success
            })
        }

        let downloadedLog = tempRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("app.log")
        #expect(FileManager.default.fileExists(atPath: downloadedLog.path))

        let downloadedData = try Data(contentsOf: downloadedLog)
        #expect(String(decoding: downloadedData, as: UTF8.self) == "service started")
    }

    @Test
    func deepDirectoryDownloadAvoidsPerChildStatFailures() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-deep-directory-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let baseClient = MockSFTPClient()
        try await baseClient.mkdir(path: "/lighting")
        try await baseClient.mkdir(path: "/lighting/docs")
        try await baseClient.mkdir(path: "/lighting/docs/specs")
        try await baseClient.mkdir(path: "/lighting/assets")
        try await baseClient.upload(data: Data("root-file".utf8), to: "/lighting/README.md")
        try await baseClient.upload(data: Data("spec-body".utf8), to: "/lighting/docs/specs/plan.md")
        try await baseClient.upload(data: Data("asset-body".utf8), to: "/lighting/assets/logo.txt")

        let guardedClient = StatBudgetSFTPClient(base: baseClient, allowedStatCalls: 1)
        let vm = FileTransferViewModel(
            sftpClient: guardedClient,
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let lightingDirectory = vm.remoteEntries.first(where: { $0.path == "/lighting" && $0.isDirectory }) else {
            Issue.record("Remote lighting directory not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: lightingDirectory)
        try await waitUntil(timeoutLoops: 80, intervalMS: 50) {
            vm.transferQueue.contains(where: {
                $0.direction == .download && $0.sourcePath == "/lighting" && $0.status == .success
            })
        }

        let downloadedRoot = tempRoot.appendingPathComponent("lighting", isDirectory: true)
        let nestedSpec = downloadedRoot.appendingPathComponent("docs/specs/plan.md")
        let nestedAsset = downloadedRoot.appendingPathComponent("assets/logo.txt")
        #expect(FileManager.default.fileExists(atPath: downloadedRoot.appendingPathComponent("README.md").path))
        #expect(FileManager.default.fileExists(atPath: nestedSpec.path))
        #expect(FileManager.default.fileExists(atPath: nestedAsset.path))
    }

    @Test
    func directoryDownloadReportsLiveProgressBeforeCompleting() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-directory-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = SlowDownloadSFTPClient(chunkDelay: .milliseconds(80), chunkCount: 20)
        let vm = FileTransferViewModel(
            sftpClient: client,
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let logs = vm.remoteEntries.first(where: { $0.path == "/logs" }) else {
            Issue.record("Remote logs directory not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: logs)

        try await waitUntil(timeoutLoops: 400, intervalMS: 25) {
            vm.transferQueue.contains(where: { $0.sourcePath == "/logs" && $0.status == .running })
        }

        try await waitUntil(timeoutLoops: 400, intervalMS: 25) {
            guard let item = vm.transferQueue.first(where: { $0.sourcePath == "/logs" }) else { return false }
            return item.totalBytes != nil && item.bytesTransferred > 0 && item.status == .running
        }

        guard let runningItem = vm.transferQueue.first(where: { $0.sourcePath == "/logs" }) else {
            Issue.record("Expected logs transfer item.")
            return
        }

        #expect(runningItem.totalBytes != nil)
        #expect(runningItem.bytesTransferred > 0)
        #expect((runningItem.speedBytesPerSecond ?? 0) > 0)
    }

    @Test
    func uploadReportsLiveSpeedBeforeCompleting() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-upload-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let localFile = tempRoot.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 32 * 1024).write(to: localFile)

        let vm = FileTransferViewModel(
            sftpClient: SlowUploadSFTPClient(chunkDelay: .milliseconds(80), chunkCount: 14),
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )
        vm.refreshLocalEntries()

        guard let localEntry = vm.localEntries.first(where: { $0.name == "payload.bin" }) else {
            Issue.record("Local upload file not found.")
            return
        }

        vm.enqueueUpload(localEntry: localEntry)

        try await waitUntil(timeoutLoops: 160, intervalMS: 25) {
            guard let item = vm.transferQueue.first(where: { $0.direction == .upload }) else { return false }
            return item.status != .queued && (item.speedBytesPerSecond ?? 0) > 0
        }

        guard let runningItem = vm.transferQueue.first(where: { $0.direction == .upload }) else {
            Issue.record("Expected upload item.")
            return
        }

        #expect((runningItem.speedBytesPerSecond ?? 0) > 0)
    }

    @Test
    func stopTransferCancelsRunningDownload() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-stop-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = SlowDownloadSFTPClient(chunkDelay: .milliseconds(80), chunkCount: 20)
        let vm = FileTransferViewModel(
            sftpClient: client,
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await waitUntil(timeoutLoops: 400, intervalMS: 25) {
            vm.transferQueue.contains(where: { $0.sourcePath == "/README.txt" && $0.status == .running })
        }
        try await waitUntil(timeoutLoops: 400, intervalMS: 25) {
            let startedPaths = await client.startedDownloadPaths()
            return startedPaths.contains("/README.txt")
        }

        guard let runningItem = vm.transferQueue.first(where: { $0.sourcePath == "/README.txt" }) else {
            Issue.record("Expected running download item.")
            return
        }

        vm.stopTransfer(itemID: runningItem.id)

        try await waitUntil(timeoutLoops: 400, intervalMS: 25) {
            vm.transferQueue.contains(where: { $0.id == runningItem.id && $0.status == .stopped })
        }
        try await waitUntil(timeoutLoops: 400, intervalMS: 25) {
            let cancelledPaths = await client.cancelledDownloadPaths()
            return cancelledPaths.contains("/README.txt")
        }

        let cancelledPaths = await client.cancelledDownloadPaths()
        #expect(cancelledPaths.contains("/README.txt"))
        #expect(FileManager.default.fileExists(atPath: runningItem.destinationPath) == false)
    }

    @Test
    func stopAllTransfersCancelsRunningAndQueuedDownloads() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-stop-all-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = SlowDownloadSFTPClient()
        let vm = FileTransferViewModel(
            sftpClient: client,
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await vm.enqueueDownload(path: "/logs/app.log")

        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            let runningCount = vm.transferQueue.filter { $0.status == .running }.count
            let queuedCount = vm.transferQueue.filter { $0.status == .queued }.count
            return runningCount == 1 && queuedCount == 1
        }

        vm.stopAllTransfers()

        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            vm.transferQueue.count == 2 && vm.transferQueue.allSatisfy { $0.status == .stopped }
        }
        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            let cancelledPaths = await client.cancelledDownloadPaths()
            return cancelledPaths.count == 1
        }

        let startedPaths = await client.startedDownloadPaths()
        let cancelledPaths = await client.cancelledDownloadPaths()
        #expect(startedPaths.count == 1)
        #expect(cancelledPaths.count == 1)
    }

    @Test
    func overallTransferProgressCompletesWhenCurrentBatchFinishesWithStoppedItems() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-current-batch-stopped-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = SlowDownloadSFTPClient()
        let vm = FileTransferViewModel(
            sftpClient: client,
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await vm.enqueueDownload(path: "/logs/app.log")
        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            vm.transferQueue.contains(where: { $0.status == .running })
        }

        vm.stopAllTransfers()

        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            vm.transferQueue.count == 2 && vm.transferQueue.allSatisfy { $0.status == .stopped }
        }

        #expect(vm.overallTransferProgress == 1)
    }

    @Test
    func overallTransferProgressResetsForNewBatchAfterPreviousBatchCompletes() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-progress-new-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = SlowDownloadSFTPClient()
        let vm = FileTransferViewModel(
            sftpClient: client,
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            vm.transferQueue.contains(where: { $0.sourcePath == "/README.txt" && $0.status == .running })
        }
        vm.stopAllTransfers()
        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            vm.transferQueue.allSatisfy { $0.status == .stopped }
        }
        #expect(vm.overallTransferProgress == 1)

        try await vm.enqueueDownload(path: "/logs/app.log")

        #expect(vm.overallTransferProgress == 0)
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
    func createRemoteFileAppearsInCurrentDirectory() async throws {
        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        await vm.refreshRemoteEntries()
        #expect(vm.remoteEntries.contains(where: { $0.path == "/notes.txt" }) == false)

        vm.createRemoteFile(named: "notes.txt", in: "/")
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/notes.txt" && !$0.isDirectory })
        }
    }

    @Test
    func createRemoteDirectoryAppearsInCurrentDirectory() async throws {
        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        await vm.refreshRemoteEntries()
        #expect(vm.remoteEntries.contains(where: { $0.path == "/assets" }) == false)

        vm.createRemoteDirectory(named: "assets", in: "/")
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/assets" && $0.isDirectory })
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
    func textDocumentLoadUsesDirectFileDownloadWhenMetadataIsKnown() async throws {
        let client = DirectDownloadOnlySFTPClient()
        let vm = FileTransferViewModel(
            sftpClient: client,
            remoteDirectoryPath: "/"
        )
        let knownModifiedAt = Date(timeIntervalSince1970: 1_729_000_000)

        let loaded = try await vm.loadTextDocument(
            path: "/README.txt",
            options: RemoteTextDocumentLoadOptions(
                knownSize: Int64(Data("Remora mock SFTP".utf8).count),
                knownModifiedAt: knownModifiedAt
            )
        )

        #expect(loaded.text == "Remora mock SFTP")
        #expect(loaded.modifiedAt == knownModifiedAt)
        #expect(await client.usedDirectDownloadPath())
        #expect(await client.statCallCount() == 0)
    }

    @Test
    func logTailReturnsOnlyRequestedTrailingLines() async throws {
        let client = MockSFTPClient()
        try await client.upload(
            data: Data("line-1\nline-2\nline-3\nline-4\nline-5".utf8),
            to: "/logs/app.log"
        )
        let vm = FileTransferViewModel(
            sftpClient: client,
            remoteDirectoryPath: "/logs"
        )

        let tail = try await vm.loadRemoteLogTail(path: "/logs/app.log", lineCount: 3)
        #expect(tail == "line-3\nline-4\nline-5")
    }

    @Test
    func largeTextDocumentIsRejectedBeforeDownloadToProtectMemory() async throws {
        let largeClient = LargeTextFileGuardSFTPClient()
        let vm = FileTransferViewModel(
            sftpClient: largeClient,
            remoteDirectoryPath: "/"
        )

        do {
            _ = try await vm.loadTextDocument(path: "/huge.log")
            Issue.record("Expected large text document load to fail.")
            return
        } catch let error as RemoteTextDocumentError {
            switch error {
            case .fileTooLarge(let actualBytes, let maxBytes):
                #expect(actualBytes > maxBytes)
                #expect(maxBytes == Int64(FileTransferViewModel.maxInlineEditableTextDocumentBytes))
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
            return
        }

        let downloadCalls = await largeClient.downloadCallCount()
        #expect(downloadCalls == 0)
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
    func recursiveRemoteAttributeSaveUpdatesNestedEntries() async throws {
        let vm = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/logs"
        )

        let attrs = RemoteFileAttributes(
            permissions: 0o700,
            owner: "ops",
            group: "wheel",
            size: 0,
            modifiedAt: Date(),
            isDirectory: true
        )

        try await vm.saveRemoteAttributes(path: "/logs", attributes: attrs, recursively: true)

        let updatedDirectory = try await vm.loadRemoteAttributes(path: "/logs")
        let updatedFile = try await vm.loadRemoteAttributes(path: "/logs/app.log")
        #expect(updatedDirectory.permissions == 0o700)
        #expect(updatedDirectory.owner == "ops")
        #expect(updatedDirectory.group == "wheel")
        #expect(updatedFile.permissions == 0o700)
        #expect(updatedFile.owner == "ops")
        #expect(updatedFile.group == "wheel")
    }

    @Test
    func compressRemoteEntriesUploadsArchiveBackToCurrentDirectory() async throws {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")

        try await vm.compressRemoteEntries(
            paths: ["/logs"],
            archiveName: "logs-backup.zip",
            format: .zip
        )

        let attributes = try await vm.loadRemoteAttributes(path: "/logs-backup.zip")
        #expect(attributes.isDirectory == false)
        #expect(attributes.size > 0)
    }

    @Test
    func extractRemoteArchiveUploadsExpandedContentToDestinationDirectory() async throws {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")

        try await vm.compressRemoteEntries(
            paths: ["/logs"],
            archiveName: "logs-backup.zip",
            format: .zip
        )
        try await vm.extractRemoteArchive(
            path: "/logs-backup.zip",
            into: "/restored"
        )

        let restoredFile = try await vm.loadRemoteAttributes(path: "/restored/logs/app.log")
        #expect(restoredFile.isDirectory == false)
        #expect(restoredFile.size > 0)
    }

    @Test
    func extractRemoteArchiveCreatesMissingDestinationDirectory() async throws {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")

        try await vm.compressRemoteEntries(
            paths: ["/logs"],
            archiveName: "logs-backup.zip",
            format: .zip
        )
        try await vm.extractRemoteArchive(
            path: "/logs-backup.zip",
            into: "/new/archive-output"
        )

        let restoredFile = try await vm.loadRemoteAttributes(path: "/new/archive-output/logs/app.log")
        #expect(restoredFile.isDirectory == false)
        #expect(restoredFile.size > 0)
    }

    @Test
    func archiveProgressStateClearsAfterCompressionCompletes() async throws {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")

        #expect(vm.archiveOperationProgress == nil)
        #expect(vm.archiveOperationStatusText == nil)

        try await vm.compressRemoteEntries(
            paths: ["/logs"],
            archiveName: "logs-backup.zip",
            format: .zip
        )

        #expect(vm.archiveOperationProgress == nil)
        #expect(vm.archiveOperationStatusText == nil)
    }

    @Test
    func currentDirectorySearchMatchesOnlyCurrentListing() async throws {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        await vm.refreshRemoteEntries()

        vm.performRemoteSearch(query: "read", scope: .currentDirectory, rootPath: "/")

        #expect(vm.remoteSearchStatus.isRunning == false)
        #expect(vm.remoteSearchStatus.rootPath == "/")
        #expect(vm.remoteSearchStatus.matchedCount == 1)
        #expect(vm.remoteSearchResults.map(\.path) == ["/README.txt"])
    }

    @Test
    func recursiveSearchFindsNestedMatchesAndPublishesProgress() async throws {
        let client = CountingMockSFTPClient(listDelayMS: 120)
        let vm = FileTransferViewModel(sftpClient: client, remoteDirectoryPath: "/")
        await vm.refreshRemoteEntries()

        vm.performRemoteSearch(query: "app", scope: .currentDirectoryRecursive, rootPath: "/")

        try await waitUntil(timeoutLoops: 60, intervalMS: 25) {
            vm.remoteSearchStatus.isRunning && vm.remoteSearchStatus.visitedCount > 0
        }

        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            !vm.remoteSearchStatus.isRunning
                && vm.remoteSearchResults.contains(where: { $0.path == "/logs/app.log" })
        }

        #expect(vm.remoteSearchStatus.matchedCount == 1)
        #expect(!vm.remoteSearchStatus.activity.isEmpty)
    }

    @Test
    func entireServerSearchAlwaysUsesRootPath() async throws {
        let client = CountingMockSFTPClient(listDelayMS: 40)
        let vm = FileTransferViewModel(sftpClient: client, remoteDirectoryPath: "/logs")
        await vm.refreshRemoteEntries()

        vm.performRemoteSearch(query: "read", scope: .entireServer, rootPath: "/logs")

        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            !vm.remoteSearchStatus.isRunning
                && vm.remoteSearchResults.contains(where: { $0.path == "/README.txt" })
        }

        #expect(vm.remoteSearchStatus.rootPath == "/")
        #expect(vm.remoteSearchStatus.scope == .entireServer)
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

    @Test
    func bindSFTPClientRestoresRemoteStatePerBindingKey() async throws {
        let clientA = CountingMockSFTPClient(listDelayMS: 0)
        let clientB = MockSFTPClient()
        let vm = FileTransferViewModel(sftpClient: DisconnectedSFTPClient(), remoteDirectoryPath: "/")

        vm.bindSFTPClient(clientA, bindingKey: "session-a", initialRemoteDirectory: "/")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteEntries.contains(where: { $0.path == "/README.txt" })
        }

        vm.navigateRemote(to: "/logs")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/logs" && vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" })
        }
        let callsBeforeSwitch = await clientA.listCallCount()

        vm.bindSFTPClient(clientB, bindingKey: "session-b", initialRemoteDirectory: "/")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/" && vm.remoteEntries.contains(where: { $0.path == "/README.txt" })
        }

        vm.bindSFTPClient(clientA, bindingKey: "session-a", initialRemoteDirectory: "/")
        #expect(vm.remoteDirectoryPath == "/logs")
        #expect(vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" }))

        let callsAfterSwitch = await clientA.listCallCount()
        #expect(callsAfterSwitch == callsBeforeSwitch)
    }

    @Test
    func openRemoteUsesEntryAbsolutePathWithoutDuplicatingParent() async {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/home")
        let absoluteEntry = RemoteFileEntry(
            name: "/home/lighting",
            path: "/home/lighting",
            size: 0,
            isDirectory: true
        )

        vm.openRemote(absoluteEntry)

        #expect(vm.remoteDirectoryPath == "/home/lighting")
    }

    @Test
    func repeatedNavigateToSameDirectoryDeduplicatesInFlightListRequests() async throws {
        let countingClient = CountingMockSFTPClient(listDelayMS: 180)
        let vm = FileTransferViewModel(sftpClient: countingClient, remoteDirectoryPath: "/")

        await vm.refreshRemoteEntries()
        let baseline = await countingClient.listCallCount()

        vm.navigateRemote(to: "/logs")
        vm.navigateRemote(to: "/logs")
        vm.navigateRemote(to: "/logs")

        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            await countingClient.listCallCount() >= baseline + 1
        }

        try await Task.sleep(for: .milliseconds(220))
        let finalCount = await countingClient.listCallCount()
        #expect(finalCount == baseline + 1)
    }

    @Test
    func navigateBackToRecentlyLoadedDirectoryUsesCache() async throws {
        let countingClient = CountingMockSFTPClient(listDelayMS: 120)
        let vm = FileTransferViewModel(sftpClient: countingClient, remoteDirectoryPath: "/")

        await vm.refreshRemoteEntries()
        let baseline = await countingClient.listCallCount()

        vm.navigateRemote(to: "/logs")
        try await waitUntil(timeoutLoops: 80, intervalMS: 25) {
            await countingClient.listCallCount() >= baseline + 1
        }
        let afterLogs = await countingClient.listCallCount()

        vm.navigateRemote(to: "/")
        try await Task.sleep(for: .milliseconds(120))

        let afterBack = await countingClient.listCallCount()
        #expect(afterBack == afterLogs)
    }

    @Test
    func remoteNavigationBackAndForwardFollowHistory() async throws {
        let vm = FileTransferViewModel(sftpClient: MockSFTPClient(), remoteDirectoryPath: "/")
        await vm.refreshRemoteEntries()

        vm.navigateRemote(to: "/logs")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/logs"
        }
        #expect(vm.canNavigateRemoteBack)

        vm.navigateRemoteBack()
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/"
        }
        #expect(vm.canNavigateRemoteForward)

        vm.navigateRemoteForward()
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/logs"
        }
    }

    @Test
    func parentDirectoryPathReturnsNilForRoot() {
        #expect(FileManagerPanelView.parentDirectoryPath(for: "/") == nil)
    }

    @Test
    func parentDirectoryPathNormalizesTrailingSlashAndReturnsParent() {
        #expect(FileManagerPanelView.parentDirectoryPath(for: "/var/log/nginx/") == "/var/log")
    }

    @Test
    func remoteLoadingStateTurnsOnDuringDirectoryFetch() async throws {
        let countingClient = CountingMockSFTPClient(listDelayMS: 220)
        let vm = FileTransferViewModel(sftpClient: countingClient, remoteDirectoryPath: "/")

        await vm.refreshRemoteEntries()
        vm.navigateRemote(to: "/logs")
        try await waitUntil(timeoutLoops: 20, intervalMS: 20) {
            vm.isRemoteLoading
        }

        try await waitUntil(timeoutLoops: 60, intervalMS: 25) {
            vm.isRemoteLoading == false
        }
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

private actor StatBudgetSFTPClient: SFTPClientProtocol {
    private let base: MockSFTPClient
    private let allowedStatCalls: Int
    private var statCalls = 0

    init(base: MockSFTPClient, allowedStatCalls: Int) {
        self.base = base
        self.allowedStatCalls = allowedStatCalls
    }

    func list(path: String) async throws -> [RemoteFileEntry] { try await base.list(path: path) }
    func download(path: String) async throws -> Data { try await base.download(path: path) }
    func download(path: String, progress: TransferProgressHandler?) async throws -> Data { try await base.download(path: path, progress: progress) }
    func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws { try await base.download(path: path, to: localFileURL, progress: progress) }
    func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String { try await base.executeRemoteShellCommand(command, timeout: timeout) }
    func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> { try await base.streamRemoteShellCommand(command) }
    func upload(data: Data, to path: String) async throws { try await base.upload(data: data, to: path) }
    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws { try await base.upload(data: data, to: path, progress: progress) }
    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws { try await base.upload(fileURL: fileURL, to: path, progress: progress) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func copy(from: String, to: String) async throws { try await base.copy(from: from, to: to) }
    func mkdir(path: String) async throws { try await base.mkdir(path: path) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws { try await base.setAttributes(path: path, attributes: attributes) }

    func stat(path: String) async throws -> RemoteFileAttributes {
        statCalls += 1
        if statCalls > allowedStatCalls {
            throw NSError(domain: "Remora.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection failed"])
        }
        return try await base.stat(path: path)
    }
}

private actor SlowDownloadSFTPClient: SFTPClientProtocol {
    private let base = MockSFTPClient()
    private let chunkDelay: Duration
    private let chunkCount: Int
    private var startedPaths: [String] = []
    private var cancelledPaths: [String] = []

    init(chunkDelay: Duration = .milliseconds(40), chunkCount: Int = 12) {
        self.chunkDelay = chunkDelay
        self.chunkCount = max(2, chunkCount)
    }

    func startedDownloadPaths() -> [String] {
        startedPaths
    }

    func cancelledDownloadPaths() -> [String] {
        cancelledPaths
    }

    func list(path: String) async throws -> [RemoteFileEntry] { try await base.list(path: path) }

    func download(path: String) async throws -> Data {
        let data = try await base.download(path: path)
        try await simulateSlowTransfer(path: path, totalBytes: Int64(data.count), progress: nil)
        return data
    }

    func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        let data = try await base.download(path: path)
        try await simulateSlowTransfer(path: path, totalBytes: Int64(data.count), progress: progress)
        return data
    }

    func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws {
        let data = try await base.download(path: path)
        try await simulateSlowTransfer(path: path, totalBytes: Int64(data.count), progress: progress)
        try FileManager.default.createDirectory(
            at: localFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localFileURL, options: .atomic)
    }

    func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String { try await base.executeRemoteShellCommand(command, timeout: timeout) }
    func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> { try await base.streamRemoteShellCommand(command) }
    func upload(data: Data, to path: String) async throws { try await base.upload(data: data, to: path) }
    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws { try await base.upload(data: data, to: path, progress: progress) }
    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws { try await base.upload(fileURL: fileURL, to: path, progress: progress) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func copy(from: String, to: String) async throws { try await base.copy(from: from, to: to) }
    func mkdir(path: String) async throws { try await base.mkdir(path: path) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func stat(path: String) async throws -> RemoteFileAttributes { try await base.stat(path: path) }
    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws { try await base.setAttributes(path: path, attributes: attributes) }

    private func simulateSlowTransfer(
        path: String,
        totalBytes: Int64,
        progress: TransferProgressHandler?
    ) async throws {
        startedPaths.append(path)
        progress?(.init(bytesTransferred: 0, totalBytes: totalBytes))

        do {
            for step in 1 ... chunkCount {
                try Task.checkCancellation()
                try await Task.sleep(for: chunkDelay)
                try Task.checkCancellation()
                let fraction = Double(step) / Double(chunkCount)
                let bytesTransferred = Int64((Double(totalBytes) * fraction).rounded(.down))
                progress?(.init(bytesTransferred: min(bytesTransferred, totalBytes), totalBytes: totalBytes))
            }
        } catch {
            if error is CancellationError {
                cancelledPaths.append(path)
            }
            throw error
        }
    }
}

private actor SlowUploadSFTPClient: SFTPClientProtocol {
    private let base = MockSFTPClient()
    private let chunkDelay: Duration
    private let chunkCount: Int

    init(chunkDelay: Duration = .milliseconds(40), chunkCount: Int = 12) {
        self.chunkDelay = chunkDelay
        self.chunkCount = max(2, chunkCount)
    }

    func list(path: String) async throws -> [RemoteFileEntry] { try await base.list(path: path) }
    func download(path: String) async throws -> Data { try await base.download(path: path) }
    func download(path: String, progress: TransferProgressHandler?) async throws -> Data { try await base.download(path: path, progress: progress) }
    func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws { try await base.download(path: path, to: localFileURL, progress: progress) }
    func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String { try await base.executeRemoteShellCommand(command, timeout: timeout) }
    func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> { try await base.streamRemoteShellCommand(command) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func copy(from: String, to: String) async throws { try await base.copy(from: from, to: to) }
    func mkdir(path: String) async throws { try await base.mkdir(path: path) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func stat(path: String) async throws -> RemoteFileAttributes { try await base.stat(path: path) }
    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws { try await base.setAttributes(path: path, attributes: attributes) }

    func upload(data: Data, to path: String) async throws {
        try await simulateSlowUpload(totalBytes: Int64(data.count), progress: nil)
        try await base.upload(data: data, to: path)
    }

    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws {
        try await simulateSlowUpload(totalBytes: Int64(data.count), progress: progress)
        try await base.upload(data: data, to: path)
    }

    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws {
        let data = try Data(contentsOf: fileURL)
        try await simulateSlowUpload(totalBytes: Int64(data.count), progress: progress)
        try await base.upload(fileURL: fileURL, to: path, progress: nil)
    }

    private func simulateSlowUpload(totalBytes: Int64, progress: TransferProgressHandler?) async throws {
        progress?(.init(bytesTransferred: 0, totalBytes: totalBytes))
        for step in 1 ... chunkCount {
            try Task.checkCancellation()
            try await Task.sleep(for: chunkDelay)
            let fraction = Double(step) / Double(chunkCount)
            let bytesTransferred = Int64((Double(totalBytes) * fraction).rounded(.down))
            progress?(.init(bytesTransferred: min(bytesTransferred, totalBytes), totalBytes: totalBytes))
        }
    }
}

actor CountingMockSFTPClient: SFTPClientProtocol {
    private let base = MockSFTPClient()
    private let listDelayNS: UInt64
    private var listCalls: Int = 0

    init(listDelayMS: UInt64) {
        self.listDelayNS = listDelayMS * 1_000_000
    }

    func listCallCount() -> Int {
        listCalls
    }

    func list(path: String) async throws -> [RemoteFileEntry] {
        listCalls += 1
        if listDelayNS > 0 {
            try await Task.sleep(nanoseconds: listDelayNS)
        }
        return try await base.list(path: path)
    }

    func download(path: String) async throws -> Data {
        try await base.download(path: path)
    }

    func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        try await base.download(path: path, progress: progress)
    }

    func upload(data: Data, to path: String) async throws {
        try await base.upload(data: data, to: path)
    }

    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(data: data, to: path, progress: progress)
    }

    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(fileURL: fileURL, to: path, progress: progress)
    }

    func rename(from: String, to: String) async throws {
        try await base.rename(from: from, to: to)
    }

    func move(from: String, to: String) async throws {
        try await base.move(from: from, to: to)
    }

    func copy(from: String, to: String) async throws {
        try await base.copy(from: from, to: to)
    }

    func mkdir(path: String) async throws {
        try await base.mkdir(path: path)
    }

    func remove(path: String) async throws {
        try await base.remove(path: path)
    }

    func stat(path: String) async throws -> RemoteFileAttributes {
        try await base.stat(path: path)
    }

    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try await base.setAttributes(path: path, attributes: attributes)
    }
}

actor DirectDownloadOnlySFTPClient: SFTPClientProtocol {
    private let base = MockSFTPClient()
    private var didUseDirectDownloadPath = false
    private var statCalls = 0

    func usedDirectDownloadPath() -> Bool {
        didUseDirectDownloadPath
    }

    func statCallCount() -> Int {
        statCalls
    }

    func list(path: String) async throws -> [RemoteFileEntry] {
        try await base.list(path: path)
    }

    func download(path: String) async throws -> Data {
        throw SFTPClientError.unsupportedOperation("download-data-path-should-not-be-used")
    }

    func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        _ = progress
        throw SFTPClientError.unsupportedOperation("download-data-path-should-not-be-used")
    }

    func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws {
        didUseDirectDownloadPath = true
        try await base.download(path: path, to: localFileURL, progress: progress)
    }

    func upload(data: Data, to path: String) async throws {
        try await base.upload(data: data, to: path)
    }

    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(data: data, to: path, progress: progress)
    }

    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(fileURL: fileURL, to: path, progress: progress)
    }

    func rename(from: String, to: String) async throws {
        try await base.rename(from: from, to: to)
    }

    func move(from: String, to: String) async throws {
        try await base.move(from: from, to: to)
    }

    func copy(from: String, to: String) async throws {
        try await base.copy(from: from, to: to)
    }

    func mkdir(path: String) async throws {
        try await base.mkdir(path: path)
    }

    func remove(path: String) async throws {
        try await base.remove(path: path)
    }

    func stat(path: String) async throws -> RemoteFileAttributes {
        statCalls += 1
        return try await base.stat(path: path)
    }

    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try await base.setAttributes(path: path, attributes: attributes)
    }
}

actor LargeTextFileGuardSFTPClient: SFTPClientProtocol {
    private let base = MockSFTPClient()
    private var downloadCalls = 0
    private let largeSize = Int64(2 * 1024 * 1024) + 1

    func downloadCallCount() -> Int {
        downloadCalls
    }

    func list(path: String) async throws -> [RemoteFileEntry] {
        try await base.list(path: path)
    }

    func download(path: String) async throws -> Data {
        downloadCalls += 1
        return try await base.download(path: path)
    }

    func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        downloadCalls += 1
        return try await base.download(path: path, progress: progress)
    }

    func upload(data: Data, to path: String) async throws {
        try await base.upload(data: data, to: path)
    }

    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(data: data, to: path, progress: progress)
    }

    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(fileURL: fileURL, to: path, progress: progress)
    }

    func rename(from: String, to: String) async throws {
        try await base.rename(from: from, to: to)
    }

    func move(from: String, to: String) async throws {
        try await base.move(from: from, to: to)
    }

    func copy(from: String, to: String) async throws {
        try await base.copy(from: from, to: to)
    }

    func mkdir(path: String) async throws {
        try await base.mkdir(path: path)
    }

    func remove(path: String) async throws {
        try await base.remove(path: path)
    }

    func stat(path: String) async throws -> RemoteFileAttributes {
        if path == "/huge.log" {
            return RemoteFileAttributes(
                permissions: 0o644,
                owner: "root",
                group: "wheel",
                size: largeSize,
                modifiedAt: Date(),
                isDirectory: false
            )
        }
        return try await base.stat(path: path)
    }

    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try await base.setAttributes(path: path, attributes: attributes)
    }
}
