import Foundation

@MainActor
final class RemoteTextEditorViewModel: ObservableObject {
    enum EditorMode: Equatable {
        case standardEditable
        case largeEditable
        case readOnlyPreview
        case rejected(actualBytes: Int64)

        var isEditable: Bool {
            switch self {
            case .standardEditable, .largeEditable:
                return true
            case .readOnlyPreview, .rejected:
                return false
            }
        }

        var lineWrapping: Bool {
            switch self {
            case .standardEditable:
                return true
            case .largeEditable, .readOnlyPreview, .rejected:
                return false
            }
        }
    }

    static let standardEditLimitBytes = 2 * 1024 * 1024
    static let largeEditLimitBytes = 10 * 1024 * 1024
    static let previewLimitBytes = 30 * 1024 * 1024

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
    @Published private(set) var editorMode: EditorMode = .standardEditable
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
            language: editorLanguage,
            isEditable: !isLoading && editorMode.isEditable,
            lineWrapping: editorMode.lineWrapping
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

    var editorModeMessage: String? {
        switch editorMode {
        case .standardEditable:
            return nil
        case .largeEditable:
            return tr("Large file mode")
        case .readOnlyPreview:
            return tr("Large file opened in read-only preview mode")
        case .rejected:
            return nil
        }
    }

    private var editorLanguage: EditorLanguage {
        switch editorMode {
        case .standardEditable:
            return language
        case .largeEditable, .readOnlyPreview, .rejected:
            return .plain
        }
    }

    func load() async {
        isLoading = true
        EditorDebugLog.log("viewModel.load path=\(path)")
        defer { isLoading = false }

        do {
            let mode = resolveEditorMode()
            editorMode = mode

            if case .rejected(let actualBytes) = mode {
                let actualText = ByteSizeFormatter.format(actualBytes)
                let maxText = ByteSizeFormatter.format(Int64(Self.previewLimitBytes))
                errorMessage = String(
                    format: tr("File is too large to open in-app (%@ > %@). Download it or use log viewing instead."),
                    actualText,
                    maxText
                )
                return
            }

            let doc = try await fileTransfer.loadTextDocument(
                path: path,
                options: loadOptions,
                maxBytes: Self.previewLimitBytes
            )
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

    private func resolveEditorMode() -> EditorMode {
        let size = loadOptions.knownSize ?? 0

        if size > Int64(Self.previewLimitBytes) {
            return .rejected(actualBytes: size)
        }
        if size > Int64(Self.largeEditLimitBytes) {
            return .readOnlyPreview
        }
        if size > Int64(Self.standardEditLimitBytes) {
            return .largeEditable
        }
        return .standardEditable
    }
}
