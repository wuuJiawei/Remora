import Foundation

@MainActor
final class RemoteTextEditorViewModel: ObservableObject {
    enum SaveStatus: Equatable {
        case idle
        case saving
        case failed(String)
    }

    @Published private(set) var encodingLabel: String = "UTF-8"
    @Published private(set) var isLoading = false
    @Published private(set) var isDirty = false
    @Published private(set) var saveStatus: SaveStatus = .idle
    @Published private(set) var contentVersion: Int = 0
    @Published private(set) var lastSavedRevision: Int?
    @Published var errorMessage: String?

    let path: String
    let language: EditorLanguage

    private let fileTransfer: FileTransferViewModel
    private let loadOptions: RemoteTextDocumentLoadOptions
    private var expectedModifiedAt: Date?
    private var saveRequestGeneration = 0
    private var contentSnapshot = ""
    private var lastSavedText = ""
    private var currentRevision = 0

    init(
        path: String,
        loadOptions: RemoteTextDocumentLoadOptions = RemoteTextDocumentLoadOptions(),
        fileTransfer: FileTransferViewModel
    ) {
        self.path = path
        self.loadOptions = loadOptions
        self.fileTransfer = fileTransfer
        self.language = .infer(from: path)
    }

    var saveRequestID: Int {
        saveRequestGeneration
    }

    var documentDescriptor: EditorDocumentDescriptor {
        EditorDocumentDescriptor(
            id: path,
            path: path,
            language: language,
            isEditable: !isLoading,
            lineWrapping: true
        )
    }

    var initialContent: EditorInitialContent {
        EditorInitialContent(
            documentID: path,
            text: contentSnapshot,
            contentVersion: contentVersion
        )
    }

    var persistedTextSnapshot: String {
        contentSnapshot
    }

    func load() async {
        isLoading = true
        EditorDebugLog.log("viewModel.load path=\(path)")
        defer { isLoading = false }

        do {
            let doc = try await fileTransfer.loadTextDocument(path: path, options: loadOptions)
            contentSnapshot = doc.text
            lastSavedText = doc.text
            currentRevision = 0
            lastSavedRevision = nil
            encodingLabel = doc.encoding
            expectedModifiedAt = doc.modifiedAt
            contentVersion += 1
            isDirty = false
            saveStatus = .idle
            EditorDebugLog.log("viewModel.load success chars=\(doc.text.count) contentVersion=\(contentVersion)")
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

    func requestSave() {
        guard !isLoading, saveStatus != .saving else { return }
        saveRequestGeneration += 1
        EditorDebugLog.log("viewModel.requestSave saveRequestID=\(saveRequestGeneration)")
    }

    func markDirty(revision: Int) {
        currentRevision = max(currentRevision, revision)
        if !isDirty {
            isDirty = true
            EditorDebugLog.log("viewModel.markDirty revision=\(revision)")
        }
    }

    func save(request: EditorSaveRequest) async {
        guard !isLoading, saveStatus != .saving else { return }

        saveStatus = .saving
        EditorDebugLog.log("viewModel.save begin rev=\(request.revision) chars=\(request.text.count)")

        do {
            expectedModifiedAt = try await fileTransfer.saveTextDocument(
                path: path,
                text: request.text,
                expectedModifiedAt: expectedModifiedAt
            )
            contentSnapshot = request.text
            lastSavedText = request.text
            lastSavedRevision = request.revision
            isDirty = request.revision < currentRevision
            saveStatus = .idle
            EditorDebugLog.log(
                "viewModel.save success rev=\(request.revision) currentRevision=\(currentRevision) contentVersion=\(contentVersion)"
            )
            errorMessage = nil
        } catch {
            saveStatus = .failed(error.localizedDescription)
            EditorDebugLog.log("viewModel.save failed error=\(error.localizedDescription)")
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
