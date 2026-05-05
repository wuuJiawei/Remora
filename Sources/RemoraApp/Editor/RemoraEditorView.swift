import SwiftUI

struct RemoraEditorView: View {
    @Binding private var text: String
    private let documentID: String
    private let language: EditorLanguage
    private let path: String?
    private let isEditable: Bool
    private let lineWrapping: Bool
    private let syncMode: EditorTextSyncMode
    private let autoScrollToBottom: Bool
    private let saveRequestID: Int
    private let savedRevision: Int?
    private let onReady: (() -> Void)?
    private let onChange: ((Int) -> Void)?
    private let onSaveRequested: ((EditorSaveRequest) -> Void)?
    private let onError: ((String) -> Void)?

    @State private var contentVersion: Int
    @State private var mirroredText: String

    init(
        text: Binding<String>,
        documentID: String,
        language: EditorLanguage = .plain,
        path: String? = nil,
        isEditable: Bool,
        lineWrapping: Bool = true,
        syncMode: EditorTextSyncMode = .continuous,
        autoScrollToBottom: Bool = false,
        saveRequestID: Int = 0,
        savedRevision: Int? = nil,
        onReady: (() -> Void)? = nil,
        onChange: ((Int) -> Void)? = nil,
        onSaveRequested: ((EditorSaveRequest) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        _text = text
        self.documentID = documentID
        self.language = language
        self.path = path
        self.isEditable = isEditable
        self.lineWrapping = lineWrapping
        self.syncMode = syncMode
        self.autoScrollToBottom = autoScrollToBottom
        self.saveRequestID = saveRequestID
        self.savedRevision = savedRevision
        self.onReady = onReady
        self.onChange = onChange
        self.onSaveRequested = onSaveRequested
        self.onError = onError
        _contentVersion = State(initialValue: 0)
        _mirroredText = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        RemoraEditorWebView(
            descriptor: EditorDocumentDescriptor(
                id: documentID,
                path: path,
                language: language,
                isEditable: isEditable,
                lineWrapping: lineWrapping
            ),
            initialContent: EditorInitialContent(
                documentID: documentID,
                text: text,
                contentVersion: contentVersion
            ),
            saveRequestID: saveRequestID,
            savedRevision: savedRevision,
            syncMode: syncMode,
            autoScrollToBottom: autoScrollToBottom,
            onReady: onReady,
            onChange: onChange,
            onEvent: nil,
            onTextChange: { newText in
                mirroredText = newText
                if text != newText {
                    text = newText
                }
            },
            onSaveRequested: onSaveRequested,
            onError: onError
        )
        .onChange(of: text) { _, newValue in
            guard newValue != mirroredText else { return }
            mirroredText = newValue
            contentVersion += 1
        }
        .onChange(of: documentID) { _, _ in
            mirroredText = text
        }
    }
}
