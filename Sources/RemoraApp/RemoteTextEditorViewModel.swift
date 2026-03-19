import Foundation

@MainActor
final class RemoteTextEditorViewModel: ObservableObject {
    @Published var text: String = ""
    @Published private(set) var encodingLabel: String = "UTF-8"
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isReadOnly = false
    @Published private(set) var hasUnsavedChanges = false
    @Published var errorMessage: String?

    let path: String

    private let fileTransfer: FileTransferViewModel
    private let loadOptions: RemoteTextDocumentLoadOptions
    private var expectedModifiedAt: Date?

    init(
        path: String,
        loadOptions: RemoteTextDocumentLoadOptions = RemoteTextDocumentLoadOptions(),
        fileTransfer: FileTransferViewModel
    ) {
        self.path = path
        self.loadOptions = loadOptions
        self.fileTransfer = fileTransfer
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let doc = try await fileTransfer.loadTextDocument(path: path, options: loadOptions)
            text = doc.text
            hasUnsavedChanges = false
            encodingLabel = doc.encoding
            expectedModifiedAt = doc.modifiedAt
            isReadOnly = doc.isReadOnly
            errorMessage = nil
        } catch let error as RemoteTextDocumentError {
            switch error {
            case .fileTooLarge(let actualBytes, let maxBytes):
                let actualText = ByteSizeFormatter.format(actualBytes)
                let maxText = ByteSizeFormatter.format(maxBytes)
                errorMessage = String(
                    format: tr("File is too large to edit in-app (%@ > %@). Please download and open it locally."),
                    actualText,
                    maxText
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateText(_ newValue: String) {
        text = newValue
        if !hasUnsavedChanges {
            hasUnsavedChanges = true
        }
    }

    func save() async {
        guard !isReadOnly else {
            errorMessage = "This file is opened as read-only due to size limits."
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            expectedModifiedAt = try await fileTransfer.saveTextDocument(
                path: path,
                text: text,
                expectedModifiedAt: expectedModifiedAt
            )
            hasUnsavedChanges = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func queueDownload() async -> Bool {
        do {
            try await fileTransfer.enqueueDownload(path: path)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
