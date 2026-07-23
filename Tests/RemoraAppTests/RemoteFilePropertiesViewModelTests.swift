import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

@MainActor
struct RemoteFilePropertiesViewModelTests {
    @Test
    func loadUsesCompleteInitialAttributesWithoutRemoteStat() async {
        let countingClient = MockRemoteFileSystem()
        let fileTransfer = FileTransferViewModel(remoteFileSystem: countingClient, remoteDirectoryPath: "/")
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
        #expect(vm.size == 321)
        #expect(vm.modifiedAt == expectedDate)
        #expect(await countingClient.attributeCallCount() == 0)
    }

    @Test
    func loadFetchesRemoteWhenInitialAttributesAreIncomplete() async {
        let countingClient = MockRemoteFileSystem()
        let fileTransfer = FileTransferViewModel(remoteFileSystem: countingClient, remoteDirectoryPath: "/")
        let initial = RemoteFileAttributes(
            permissions: nil,
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

        #expect(vm.permissionsText == "644")
        #expect(await countingClient.attributeCallCount() == 1)
    }
}
