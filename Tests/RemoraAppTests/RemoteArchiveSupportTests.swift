import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

struct RemoteArchiveSupportTests {
    @Test
    func capabilityProbeParsesAvailableTools() {
        let toolchain = RemoteArchiveCommandBuilder.parseCapabilityProbeOutput(
            """
            tar=OK
            zip=OK
            unzip=MISSING
            sevenZip=7zz
            unrar=MISSING
            gzip=OK
            """
        )

        #expect(toolchain.tarAvailable)
        #expect(toolchain.zipAvailable)
        #expect(toolchain.unzipAvailable == false)
        #expect(toolchain.sevenZipCommand == "7zz")
        #expect(toolchain.unrarAvailable == false)
        #expect(toolchain.gzipAvailable)
    }

    @Test
    func sameNameDirectoryDropsArchiveSuffix() {
        #expect(
            RemoteArchiveCommandBuilder.sameNameDirectory(
                for: "/home/app/logs.tar.gz",
                format: .tarGz
            ) == "/home/app/logs"
        )
        #expect(
            RemoteArchiveCommandBuilder.sameNameDirectory(
                for: "/backup/demo.7z",
                format: .sevenZip
            ) == "/backup/demo"
        )
    }

    @Test
    func unsafeArchiveEntriesAreRejected() throws {
        #expect(throws: ArchiveSupportError.self) {
            try RemoteArchiveCommandBuilder.validateSafeArchiveEntries([
                "logs/app.log",
                "../etc/passwd",
            ])
        }
    }

    @Test
    func compressionScriptUsesRemoteCommandsOnly() throws {
        let toolchain = RemoteArchiveToolchain(
            tarAvailable: true,
            zipAvailable: true,
            unzipAvailable: true,
            sevenZipCommand: "7z",
            unrarAvailable: true,
            gzipAvailable: true
        )

        let script = try RemoteArchiveCommandBuilder.compressionScript(
            parentDirectory: "/srv/app",
            sourceNames: ["logs", "README.md"],
            destinationPath: "/srv/app/archive.tar.gz",
            format: .tarGz,
            toolchain: toolchain
        )

        #expect(script.contains("tar -czf"))
        #expect(script.contains("-C '/srv/app'"))
        #expect(script.contains("'logs' 'README.md'"))
        #expect(!script.contains("upload"))
        #expect(!script.contains("download"))
    }

    @Test
    func nativeCommandExecutorPerformsRemoteArchiveRoundTrip() async throws {
        let fileSystem = MockRemoteFileSystem()
        let executor = MockRemoteCommandExecutor(fileSystem: fileSystem)
        let toolchain = RemoteArchiveToolchain(
            tarAvailable: true,
            zipAvailable: true,
            unzipAvailable: true,
            sevenZipCommand: "7z",
            unrarAvailable: true,
            gzipAvailable: true
        )

        let compressCommand = try RemoteArchiveCommandBuilder.compressionScript(
            parentDirectory: "/",
            sourceNames: ["logs"],
            destinationPath: "/logs-backup.tar.gz",
            format: .tarGz,
            toolchain: toolchain
        )
        _ = try await executor.execute(
            RemoteCommandRequest(executable: .shell(compressCommand))
        )

        let archive = try await fileSystem.attributes(
            path: "/logs-backup.tar.gz",
            followSymbolicLinks: true
        )
        #expect(archive.isDirectory == false)

        let listCommand = try RemoteArchiveCommandBuilder.listArchiveEntriesScript(
            archivePath: "/logs-backup.tar.gz",
            format: .tarGz,
            toolchain: toolchain
        )
        let listResult = try await executor.execute(
            RemoteCommandRequest(executable: .shell(listCommand))
        )
        let listed = String(decoding: listResult.standardOutput, as: UTF8.self)
        #expect(listed.contains("logs/app.log"))

        let extractCommand = try RemoteArchiveCommandBuilder.extractArchiveScript(
            archivePath: "/logs-backup.tar.gz",
            destinationDirectory: "/restored",
            format: .tarGz,
            toolchain: toolchain
        )
        _ = try await executor.execute(
            RemoteCommandRequest(executable: .shell(extractCommand))
        )

        let restored = try await fileSystem.attributes(
            path: "/restored/logs/app.log",
            followSymbolicLinks: true
        )
        #expect(restored.isDirectory == false)
    }

    @MainActor
    @Test
    func remoteClipboardTracksConnectionMetadata() async throws {
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/logs")
        vm.bindRemoteFileSystem(MockRemoteFileSystem(), bindingKey: "host-a", initialRemoteDirectory: "/logs")
        vm.copyRemoteEntries(paths: ["/logs/app.log"], mode: .copy)

        let clipboard = try #require(vm.remoteClipboard)
        #expect(clipboard.sourceConnectionID == "host-a")
        #expect(clipboard.sourceParentDirectory == "/logs")
        #expect(clipboard.items.map(\.name) == ["app.log"])
    }

    @MainActor
    @Test
    func pasteIsBlockedAcrossConnections() async throws {
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
        vm.bindRemoteFileSystem(MockRemoteFileSystem(), bindingKey: "host-a", initialRemoteDirectory: "/")
        vm.copyRemoteEntries(paths: ["/logs/app.log"], mode: .copy)
        vm.bindRemoteFileSystem(MockRemoteFileSystem(), bindingKey: "host-b", initialRemoteDirectory: "/")

        let result = await vm.pasteRemoteEntriesResult(into: "/")
        #expect(result == .blockedCrossConnection)
    }

    @MainActor
    @Test
    func cloneNamingUsesCopySuffixAndPreservesCompoundExtension() async throws {
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
        let next = try await vm.nextClonePathForTests("/archive.tar.gz", isDirectory: false)
        #expect(next == "/archive copy.tar.gz")
    }

    @MainActor
    @Test
    func pasteKeepsClipboardForCopyButClearsForCut() async throws {
        let copyVM = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
        copyVM.bindRemoteFileSystem(MockRemoteFileSystem(), bindingKey: "host-a", initialRemoteDirectory: "/")
        copyVM.copyRemoteEntries(paths: ["/README.txt"], mode: .copy)
        let copyResult = await copyVM.pasteRemoteEntriesResult(into: "/logs")
        #expect(copyResult == .success(destinationDirectory: "/logs", pastedCount: 1, clearsClipboard: false))
        #expect(copyVM.remoteClipboard != nil)

        let cutVM = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
        cutVM.bindRemoteFileSystem(MockRemoteFileSystem(), bindingKey: "host-a", initialRemoteDirectory: "/")
        cutVM.copyRemoteEntries(paths: ["/README.txt"], mode: .cut)
        let cutResult = await cutVM.pasteRemoteEntriesResult(into: "/logs")
        #expect(cutResult == .success(destinationDirectory: "/logs", pastedCount: 1, clearsClipboard: true))
        #expect(cutVM.remoteClipboard == nil)
    }

    @MainActor
    @Test
    func moveRemoteEntriesResultReturnsMovedCount() async throws {
        let vm = FileTransferViewModel(remoteFileSystem: MockRemoteFileSystem(), remoteDirectoryPath: "/")
        let movedCount = await vm.moveRemoteEntriesResult(paths: ["/README.txt"], toDirectory: "/logs")
        #expect(movedCount == 1)
        await vm.refreshRemoteEntries()
        vm.navigateRemote(to: "/logs")
        await vm.refreshRemoteEntries()
        #expect(vm.remoteEntries.contains(where: { $0.path == "/logs/README.txt" }))
    }
}
