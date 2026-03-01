import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

@MainActor
struct RemoteFilePropertiesViewModelTests {
    @Test
    func loadUsesCompleteInitialAttributesWithoutRemoteStat() async {
        let countingClient = StatCountingMockSFTPClient()
        let fileTransfer = FileTransferViewModel(sftpClient: countingClient, remoteDirectoryPath: "/")
        let expectedDate = Date(timeIntervalSince1970: 1_800_000_100)
        let initial = RemoteFileAttributes(
            permissions: 0o640,
            owner: "root",
            group: "root",
            size: 321,
            modifiedAt: expectedDate,
            isDirectory: false
        )
        let vm = RemoteFilePropertiesViewModel(
            path: "/README.txt",
            fileTransfer: fileTransfer,
            initialAttributes: initial
        )

        await vm.load()

        #expect(vm.permissionsText == "640")
        #expect(vm.ownerText == "root")
        #expect(vm.groupText == "root")
        #expect(vm.size == 321)
        #expect(vm.modifiedAt == expectedDate)
        #expect(await countingClient.statCallCount() == 0)
    }

    @Test
    func loadFetchesRemoteWhenInitialAttributesAreIncomplete() async {
        let countingClient = StatCountingMockSFTPClient()
        let fileTransfer = FileTransferViewModel(sftpClient: countingClient, remoteDirectoryPath: "/")
        let initial = RemoteFileAttributes(
            permissions: 0o644,
            owner: nil,
            group: nil,
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isDirectory: false
        )
        let vm = RemoteFilePropertiesViewModel(
            path: "/README.txt",
            fileTransfer: fileTransfer,
            initialAttributes: initial
        )

        await vm.load()

        #expect(vm.ownerText == "mock")
        #expect(vm.groupText == "mock")
        #expect(await countingClient.statCallCount() == 1)
    }
}

actor StatCountingMockSFTPClient: SFTPClientProtocol {
    private let base = MockSFTPClient()
    private var statCalls = 0

    func statCallCount() -> Int {
        statCalls
    }

    func list(path: String) async throws -> [RemoteFileEntry] {
        try await base.list(path: path)
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
        statCalls += 1
        return try await base.stat(path: path)
    }

    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try await base.setAttributes(path: path, attributes: attributes)
    }
}
