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

    @Test
    @MainActor
    func editorUsesStandardModeForSmallFiles() async throws {
        let fileTransfer = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        let viewModel = RemoteTextEditorViewModel(
            path: "/README.txt",
            loadOptions: RemoteTextDocumentLoadOptions(
                knownSize: 1 * 1024 * 1024
            ),
            fileTransfer: fileTransfer
        )

        await viewModel.load()

        #expect(viewModel.editorMode == .standardEditable)
        #expect(viewModel.documentDescriptor.isEditable)
        #expect(viewModel.documentDescriptor.lineWrapping)
        #expect(viewModel.documentDescriptor.language == .plain || viewModel.documentDescriptor.language == .infer(from: "/README.txt"))
    }

    @Test
    @MainActor
    func editorUsesLargeEditableModeForMediumFiles() async throws {
        let client = MockSFTPClient()
        try await client.upload(data: Data(repeating: 0x61, count: 5 * 1024 * 1024), to: "/large.txt")
        let fileTransfer = FileTransferViewModel(
            sftpClient: client,
            remoteDirectoryPath: "/"
        )
        let viewModel = RemoteTextEditorViewModel(
            path: "/large.txt",
            loadOptions: RemoteTextDocumentLoadOptions(
                knownSize: 5 * 1024 * 1024
            ),
            fileTransfer: fileTransfer
        )

        await viewModel.load()

        #expect(viewModel.editorMode == .largeEditable)
        #expect(viewModel.documentDescriptor.isEditable)
        #expect(!viewModel.documentDescriptor.lineWrapping)
        #expect(viewModel.documentDescriptor.language == .plain)
    }

    @Test
    @MainActor
    func editorUsesReadOnlyPreviewModeForLargeFiles() async throws {
        let client = MockSFTPClient()
        try await client.upload(data: Data(repeating: 0x61, count: 15 * 1024 * 1024), to: "/preview.txt")
        let fileTransfer = FileTransferViewModel(
            sftpClient: client,
            remoteDirectoryPath: "/"
        )
        let viewModel = RemoteTextEditorViewModel(
            path: "/preview.txt",
            loadOptions: RemoteTextDocumentLoadOptions(
                knownSize: 15 * 1024 * 1024
            ),
            fileTransfer: fileTransfer
        )

        await viewModel.load()

        #expect(viewModel.editorMode == .readOnlyPreview)
        #expect(!viewModel.documentDescriptor.isEditable)
        #expect(!viewModel.documentDescriptor.lineWrapping)
        #expect(viewModel.documentDescriptor.language == .plain)
    }

    @Test
    @MainActor
    func editorRejectsVeryLargeFiles() async throws {
        let fileTransfer = FileTransferViewModel(
            sftpClient: MockSFTPClient(),
            remoteDirectoryPath: "/"
        )
        let hugeSize = Int64(35 * 1024 * 1024)
        let viewModel = RemoteTextEditorViewModel(
            path: "/huge.txt",
            loadOptions: RemoteTextDocumentLoadOptions(
                knownSize: hugeSize
            ),
            fileTransfer: fileTransfer
        )

        await viewModel.load()

        #expect(viewModel.editorMode == .rejected(actualBytes: hugeSize))
        #expect(viewModel.errorMessage?.contains("too large") == true)
        #expect(viewModel.persistedTextSnapshot.isEmpty)
    }
}
