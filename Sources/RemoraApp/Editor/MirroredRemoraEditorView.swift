import SwiftUI

// Compatibility wrapper for small local text-editing surfaces that still need a SwiftUI text binding.
// Do not use this for production remote file editing, SFTP-backed documents, logs, or large files.
// Use RemoraEditorView for stable descriptor/content-version driven editor ownership.
struct MirroredRemoraEditorView: View {
    @Binding private var text: String
    private let documentID: String
    private let language: EditorLanguage
    private let path: String?
    private let isEditable: Bool
    private let lineWrapping: Bool
    private let autoScrollToBottom: Bool
    private let insertion: EditorTextInsertion?
    private let onReady: (() -> Void)?
    private let onChange: ((Int) -> Void)?
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
        autoScrollToBottom: Bool = false,
        insertion: EditorTextInsertion? = nil,
        onReady: (() -> Void)? = nil,
        onChange: ((Int) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        _text = text
        self.documentID = documentID
        self.language = language
        self.path = path
        self.isEditable = isEditable
        self.lineWrapping = lineWrapping
        self.autoScrollToBottom = autoScrollToBottom
        self.insertion = insertion
        self.onReady = onReady
        self.onChange = onChange
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
            textInsertion: insertion,
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
            onSaveRequested: nil,
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
