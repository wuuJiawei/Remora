import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

@MainActor
struct FileTransferViewModelTests {
    @Test
    func loadedDirectorySnapshotDistinguishesUnloadedFromEmptyDirectory() async throws {
        let vm = FileTransferViewModel(remoteFileSystem: nil)
        #expect(vm.loadedRemoteDirectorySnapshot == nil)

        vm.bindRemoteFileSystem(
            MockRemoteFileSystem(includeDefaultFixtures: false),
            initialRemoteDirectory: "/"
        )

        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.loadedRemoteDirectorySnapshot != nil
        }
        #expect(vm.loadedRemoteDirectorySnapshot?.path == "/")
        #expect(vm.loadedRemoteDirectorySnapshot?.entries.isEmpty == true)
    }

    @Test
    func uploadThenDownloadRoundTrip() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let localFile = tempRoot.appendingPathComponent("hello.txt")
        try Data("hello-remora".utf8).write(to: localFile)

        let vm = FileTransferViewModel(
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
    func downloadsUseBoundedRemoteFileHandleReads() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-direct-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = MockRemoteFileSystem()
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
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

        #expect(await client.readPaths().contains("/README.txt"))
        #expect(await client.maximumRequestedReadSize() <= 64 * 1_024)
    }

    @Test
    func directoryDownloadPreservesNestedStructure() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-directory-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vm = FileTransferViewModel(
            remoteFileSystem: MockRemoteFileSystem(),
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

        let guardedClient = MockRemoteFileSystem(
            configuration: .init(allowedAttributeCalls: 1)
        )
        try await guardedClient.seedDirectory(at: "/lighting")
        try await guardedClient.seedDirectory(at: "/lighting/docs")
        try await guardedClient.seedDirectory(at: "/lighting/docs/specs")
        try await guardedClient.seedDirectory(at: "/lighting/assets")
        try await guardedClient.seedFile(data: Data("root-file".utf8), at: "/lighting/README.md")
        try await guardedClient.seedFile(data: Data("spec-body".utf8), at: "/lighting/docs/specs/plan.md")
        try await guardedClient.seedFile(data: Data("asset-body".utf8), at: "/lighting/assets/logo.txt")
        let vm = FileTransferViewModel(
            remoteFileSystem: guardedClient,
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

        let client = MockRemoteFileSystem(
            configuration: .init(
                readDelay: .milliseconds(80),
                maximumReadChunkSize: 1
            )
        )
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
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
            remoteFileSystem: MockRemoteFileSystem(
                configuration: .init(
                    writeDelay: .milliseconds(80),
                    maximumWriteChunkSize: 2 * 1024
                )
            ),
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

        let client = MockRemoteFileSystem(
            configuration: .init(
                readDelay: .milliseconds(80),
                maximumReadChunkSize: 1
            )
        )
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
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
            let startedPaths = await client.readPaths()
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
            let cancelledPaths = await client.cancelledReads()
            return cancelledPaths.contains("/README.txt")
        }

        let cancelledPaths = await client.cancelledReads()
        #expect(cancelledPaths.contains("/README.txt"))
        #expect(FileManager.default.fileExists(atPath: runningItem.destinationPath) == false)
    }

    @Test
    func stopAllTransfersCancelsRunningAndQueuedDownloads() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-stop-all-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = MockRemoteFileSystem(
            configuration: .init(readDelay: .milliseconds(40), maximumReadChunkSize: 1)
        )
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
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
            let cancelledPaths = await client.cancelledReads()
            return cancelledPaths.count == 1
        }

        let startedPaths = await client.readPaths()
        let cancelledPaths = await client.cancelledReads()
        #expect(startedPaths.count == 1)
        #expect(cancelledPaths.count == 1)
    }

    @Test
    func overallTransferProgressCompletesWhenCurrentBatchFinishesWithStoppedItems() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-current-batch-stopped-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let client = MockRemoteFileSystem(
            configuration: .init(readDelay: .milliseconds(40), maximumReadChunkSize: 1)
        )
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
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

        let client = MockRemoteFileSystem(
            configuration: .init(readDelay: .milliseconds(40), maximumReadChunkSize: 1)
        )
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
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
        let fileSystem = MockRemoteFileSystem()
        try await fileSystem.seedDirectory(at: "/docs")
        let vm = FileTransferViewModel(
            remoteFileSystem: fileSystem,
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
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
            remoteDirectoryPath: "/"
        )

        let loaded = try await vm.loadTextDocument(path: "/README.txt")
        #expect(loaded.text.contains("Remora"))
        #expect(loaded.encoding == "UTF-8")

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
    func textDocumentLoadSkipsStatWhenMetadataIsKnown() async throws {
        let client = MockRemoteFileSystem()
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
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
        #expect(await client.readPaths().contains("/README.txt"))
        #expect(await client.attributeCallCount() == 0)
    }

    @Test
    func logTailReturnsOnlyRequestedTrailingLines() async throws {
        let client = MockRemoteFileSystem()
        try await client.seedFile(
            data: Data("line-1\nline-2\nline-3\nline-4\nline-5".utf8),
            at: "/logs/app.log"
        )
        let executor = MockRemoteCommandExecutor(fileSystem: client)
        let vm = FileTransferViewModel(
            remoteFileSystem: client,
            remoteCommandExecutor: executor,
            remoteDirectoryPath: "/logs"
        )

        let tail = try await vm.loadRemoteLogTail(path: "/logs/app.log", lineCount: 3)
        #expect(tail == "line-3\nline-4\nline-5")
    }

    @Test
    func largeTextDocumentIsRejectedBeforeDownloadToProtectMemory() async throws {
        let largeSize = Int64(FileTransferViewModel.maxInlineEditableTextDocumentBytes) + 1
        let largeClient = MockRemoteFileSystem(
            configuration: .init(reportedSizes: ["/huge.log": largeSize])
        )
        try await largeClient.seedFile(data: Data(), at: "/huge.log")
        let vm = FileTransferViewModel(
            remoteFileSystem: largeClient,
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

        #expect(await largeClient.readOpenCallCount() == 0)
    }

    @Test
    func remotePropertiesRoundTripSupportsLoadAndSave() async throws {
        let vm = FileTransferViewModel(
            remoteFileSystem: MockRemoteFileSystem(),
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
            remoteFileSystem: MockRemoteFileSystem(),
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
        let fileSystem = MockRemoteFileSystem()
        let vm = FileTransferViewModel(
            remoteFileSystem: fileSystem,
            remoteCommandExecutor: MockRemoteCommandExecutor(fileSystem: fileSystem),
            remoteDirectoryPath: "/"
        )

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
        let fileSystem = MockRemoteFileSystem()
        let vm = FileTransferViewModel(
            remoteFileSystem: fileSystem,
            remoteCommandExecutor: MockRemoteCommandExecutor(fileSystem: fileSystem),
            remoteDirectoryPath: "/"
        )

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
        let fileSystem = MockRemoteFileSystem()
        let vm = FileTransferViewModel(
            remoteFileSystem: fileSystem,
            remoteCommandExecutor: MockRemoteCommandExecutor(fileSystem: fileSystem),
            remoteDirectoryPath: "/"
        )

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
        let fileSystem = MockRemoteFileSystem()
        let vm = FileTransferViewModel(
            remoteFileSystem: fileSystem,
            remoteCommandExecutor: MockRemoteCommandExecutor(fileSystem: fileSystem),
            remoteDirectoryPath: "/"
        )

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
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
        await vm.refreshRemoteEntries()

        vm.performRemoteSearch(query: "read", scope: .currentDirectory, rootPath: "/")

        #expect(vm.remoteSearchStatus.isRunning == false)
        #expect(vm.remoteSearchStatus.rootPath == "/")
        #expect(vm.remoteSearchStatus.matchedCount == 1)
        #expect(vm.remoteSearchResults.map(\.path) == ["/README.txt"])
    }

    @Test
    func recursiveSearchFindsNestedMatchesAndPublishesProgress() async throws {
        let client = MockRemoteFileSystem(
            configuration: .init(listDelay: .milliseconds(120))
        )
        let vm = FileTransferViewModel(remoteFileSystem: client, remoteDirectoryPath: "/")
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
        let client = MockRemoteFileSystem(
            configuration: .init(listDelay: .milliseconds(40))
        )
        let vm = FileTransferViewModel(remoteFileSystem: client, remoteDirectoryPath: "/logs")
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
    func bindRemoteFileSystemSwitchesRemoteSourceAndResetsTransientState() async throws {
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
        await vm.refreshRemoteEntries()
        #expect(vm.remoteEntries.contains(where: { $0.path == "/README.txt" }))

        vm.performContextAction(.copy(paths: ["/README.txt"]))
        vm.enqueueDownload(paths: ["/README.txt"])
        #expect(vm.remoteClipboard != nil)
        #expect(!vm.transferQueue.isEmpty)

        let nextClient = MockRemoteFileSystem()
        try await nextClient.removeFile(path: "/README.txt")
        try await nextClient.seedFile(data: Data("next".utf8), at: "/next.txt")

        vm.bindRemoteFileSystem(nextClient, initialRemoteDirectory: "/")

        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            await vm.refreshRemoteEntries()
            return vm.remoteEntries.contains(where: { $0.path == "/next.txt" })
        }

        #expect(vm.remoteEntries.contains(where: { $0.path == "/next.txt" }))
        #expect(!vm.remoteEntries.contains(where: { $0.path == "/README.txt" }))
        #expect(vm.remoteClipboard != nil)
        #expect(await vm.pasteRemoteEntriesResult(into: "/") == .blockedCrossConnection)
        #expect(vm.transferQueue.isEmpty)
    }

    @Test
    func bindRemoteFileSystemRestoresRemoteStatePerBindingKey() async throws {
        let clientA = MockRemoteFileSystem()
        let clientB = MockRemoteFileSystem()
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")

        vm.bindRemoteFileSystem(clientA, bindingKey: "session-a", initialRemoteDirectory: "/")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteEntries.contains(where: { $0.path == "/README.txt" })
        }

        vm.navigateRemote(to: "/logs")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/logs" && vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" })
        }
        let callsBeforeSwitch = await clientA.listCallCount()

        vm.bindRemoteFileSystem(clientB, bindingKey: "session-b", initialRemoteDirectory: "/")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/" && vm.remoteEntries.contains(where: { $0.path == "/README.txt" })
        }

        vm.bindRemoteFileSystem(clientA, bindingKey: "session-a", initialRemoteDirectory: "/")
        #expect(vm.remoteDirectoryPath == "/logs")
        #expect(vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" }))

        let callsAfterSwitch = await clientA.listCallCount()
        #expect(callsAfterSwitch == callsBeforeSwitch)
    }

    @Test
    func administratorModeReusesSessionAndRestoresNormalBindingState() async throws {
        let normalFileSystem = MockRemoteFileSystem()
        let administratorFileSystem = MockRemoteFileSystem()
        let executor = MockRemoteCommandExecutor(responses: [:])
        let session = AdministratorFileTestSession(
            normalFileSystem: normalFileSystem,
            administratorFileSystem: administratorFileSystem,
            executor: executor
        )
        let lease = AdministratorFileTestLease(session: session)
        let vm = FileTransferViewModel(remoteDirectoryPath: "/")

        vm.attachNativeSession(
            lease: lease,
            executor: executor,
            fileSystem: normalFileSystem,
            bindingKey: "session-a",
            initialRemoteDirectory: "/"
        )
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteEntries.contains(where: { $0.path == "/README.txt" })
        }
        vm.navigateRemote(to: "/logs")
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            vm.remoteDirectoryPath == "/logs"
                && vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" })
        }

        vm.setRemoteAdministratorMode(true)
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            await session.administratorFileSystemRequestCount == 1
                && vm.remoteLoadErrorMessage == nil
                && vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" })
        }
        #expect(await lease.sessionRequestCount == 1)

        vm.setRemoteAdministratorMode(false)
        #expect(vm.remoteDirectoryPath == "/logs")
        #expect(vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" }))
        try await waitUntil(timeoutLoops: 40, intervalMS: 25) {
            await administratorFileSystem.isClosedForTesting()
        }

        await vm.refreshRemoteEntries()
        #expect(vm.remoteEntries.contains(where: { $0.path == "/logs/app.log" }))
        await vm.releaseNativeSession()
        #expect(await lease.releaseCount == 1)
    }

    @Test
    func openRemoteUsesEntryAbsolutePathWithoutDuplicatingParent() async {
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/home")
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
        let countingClient = MockRemoteFileSystem(
            configuration: .init(listDelay: .milliseconds(180))
        )
        let vm = FileTransferViewModel(remoteFileSystem: countingClient, remoteDirectoryPath: "/")

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
        let countingClient = MockRemoteFileSystem(
            configuration: .init(listDelay: .milliseconds(120))
        )
        let vm = FileTransferViewModel(remoteFileSystem: countingClient, remoteDirectoryPath: "/")

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
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
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
        let countingClient = MockRemoteFileSystem(
            configuration: .init(listDelay: .milliseconds(220))
        )
        let vm = FileTransferViewModel(remoteFileSystem: countingClient, remoteDirectoryPath: "/")

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

private actor AdministratorFileTestLease: RemoteSessionLeaseProtocol {
    nonisolated let id = UUID()
    private let remoteSession: any RemoteSessionProtocol
    private(set) var sessionRequestCount = 0
    private(set) var releaseCount = 0

    init(session: any RemoteSessionProtocol) {
        remoteSession = session
    }

    func session() async throws -> any RemoteSessionProtocol {
        sessionRequestCount += 1
        return remoteSession
    }

    func release() async {
        releaseCount += 1
    }
}

private actor AdministratorFileTestSession: RemoteSessionProtocol {
    nonisolated let id = UUID()
    private let normalFileSystem: any RemoteFileSystem
    private let rootFileSystem: any RemoteFileSystem
    private let executor: any RemoteCommandExecutorProtocol
    private(set) var administratorFileSystemRequestCount = 0

    init(
        normalFileSystem: any RemoteFileSystem,
        administratorFileSystem: any RemoteFileSystem,
        executor: any RemoteCommandExecutorProtocol
    ) {
        self.normalFileSystem = normalFileSystem
        rootFileSystem = administratorFileSystem
        self.executor = executor
    }

    func identitySnapshot() async -> RemoteSessionIdentitySnapshot {
        let hostID = UUID()
        return RemoteSessionIdentitySnapshot(
            sessionID: id,
            key: RemoteSessionKey(
                route: .direct(
                    DirectConnectionRoute(
                        endpoint: RemoteEndpoint(hostname: "fixture.test"),
                        username: "tester"
                    )
                ),
                target: RemoteTargetIdentity(
                    savedHostID: hostID,
                    routeProviderID: "direct",
                    assetID: hostID.uuidString,
                    assetDisplayName: "Fixture",
                    accountUsername: "tester"
                ),
                authenticationIdentity: RemoteAuthenticationIdentity(
                    username: "tester",
                    method: .password
                ),
                hostKeyPolicyID: "fixture"
            ),
            state: .ready
        )
    }

    func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol {
        _ = pty
        throw RemoteOperationError(
            category: .channel,
            code: "fixture_shell_unavailable",
            safeDiagnosticMessage: "Fixture does not provide a shell"
        )
    }

    func commandExecutor() async throws -> any RemoteCommandExecutorProtocol {
        executor
    }

    func fileSystem() async throws -> any RemoteFileSystem {
        normalFileSystem
    }

    func administratorFileSystem() async throws -> any RemoteFileSystem {
        administratorFileSystemRequestCount += 1
        return rootFileSystem
    }

    func close() async { }
}
