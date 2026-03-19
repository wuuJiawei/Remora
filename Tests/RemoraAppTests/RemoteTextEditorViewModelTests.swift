import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct RemoteTextEditorViewModelTests {
    @Test
    @MainActor
    func editorTracksDirtyStateWithoutFullStringComparison() async throws {
        let fileTransfer = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        let viewModel = RemoteTextEditorViewModel(
            path: "/README.txt",
            fileTransfer: fileTransfer
        )

        await viewModel.load()
        #expect(viewModel.hasUnsavedChanges == false)

        viewModel.updateText(viewModel.text + "\nupdated")
        #expect(viewModel.hasUnsavedChanges)

        await viewModel.save()
        #expect(viewModel.hasUnsavedChanges == false)
    }

    @Test
    @MainActor
    func editorCanQueueDownloadForCurrentFile() async throws {
        let fileTransfer = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        let viewModel = RemoteTextEditorViewModel(
            path: "/README.txt",
            fileTransfer: fileTransfer
        )

        let queued = await viewModel.queueDownload()

        #expect(queued)
        #expect(fileTransfer.transferQueue.count == 1)
        #expect(fileTransfer.transferQueue.first?.direction == .download)
        #expect(fileTransfer.transferQueue.first?.sourcePath == "/README.txt")
    }
}
