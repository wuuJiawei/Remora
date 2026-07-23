import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

@MainActor
struct RemotePermissionsEditorViewModelTests {
    @Test
    func permissionBitsFormatsModeAsFourDigitOctal() {
        let bits = RemotePermissionBits(mode: 0o754)

        #expect(bits.octalText == "0754")
        #expect(bits.owner.read)
        #expect(bits.owner.write)
        #expect(bits.owner.execute)
        #expect(bits.group.read)
        #expect(!bits.group.write)
        #expect(bits.group.execute)
        #expect(bits.other.read)
        #expect(!bits.other.write)
        #expect(!bits.other.execute)
    }

    @Test
    func togglingPermissionUpdatesOctalText() {
        var bits = RemotePermissionBits(mode: 0o640)

        bits.set(scope: .other, permission: .read, enabled: true)

        #expect(bits.octalText == "0644")
    }

    @Test
    func parsingOctalTextUpdatesPermissionBits() throws {
        let bits = try #require(RemotePermissionBits(octalText: "0777"))

        #expect(bits.owner.read && bits.owner.write && bits.owner.execute)
        #expect(bits.group.read && bits.group.write && bits.group.execute)
        #expect(bits.other.read && bits.other.write && bits.other.execute)
    }

    @Test
    func recursiveSaveAppliesPermissionsOwnerAndGroupToChildren() async throws {
        let fileTransfer = FileTransferViewModel(
            remoteFileSystem: MockRemoteFileSystem(),
            remoteDirectoryPath: "/logs"
        )
        let initial = try await fileTransfer.loadRemoteAttributes(path: "/logs")
        let viewModel = RemotePermissionsEditorViewModel(
            path: "/logs",
            fileTransfer: fileTransfer,
            initialAttributes: initial
        )

        await viewModel.load()
        viewModel.permissionsText = "0700"
        viewModel.ownerText = "ops"
        viewModel.groupText = "wheel"
        viewModel.applyRecursively = true
        await viewModel.save()

        let updatedDirectory = try await fileTransfer.loadRemoteAttributes(path: "/logs")
        let updatedFile = try await fileTransfer.loadRemoteAttributes(path: "/logs/app.log")
        #expect(updatedDirectory.permissions == 0o700)
        #expect(updatedDirectory.owner == "ops")
        #expect(updatedDirectory.group == "wheel")
        #expect(updatedFile.permissions == 0o700)
        #expect(updatedFile.owner == "ops")
        #expect(updatedFile.group == "wheel")
    }
}
