import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct RemoteTextEditorViewModelTests {
    @Test
    @MainActor
    func editorLoadsAndSavesTextThroughViewModel() async throws {
        let fileTransfer = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        let viewModel = RemoteTextEditorViewModel(
            path: "/README.txt",
            fileTransfer: fileTransfer
        )

        await viewModel.load()
        #expect(viewModel.persistedTextSnapshot.contains("Remora"))

        let updated = viewModel.persistedTextSnapshot + "\nupdated"
        await viewModel.save(request: EditorSaveRequest(revision: 1, text: updated))
        #expect(viewModel.persistedTextSnapshot.contains("updated"))
        #expect(viewModel.contentVersion == 1)
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
