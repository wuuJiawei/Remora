import SwiftUI

struct RemoraEditorView: View {
    private let descriptor: EditorDocumentDescriptor
    private let initialContent: EditorInitialContent
    private let saveRequestID: Int
    private let savedRevision: Int?
    private let autoScrollToBottom: Bool
    private let onReady: (() -> Void)?
    private let onChange: ((Int) -> Void)?
    private let onSaveRequested: ((EditorSaveRequest) -> Void)?
    private let onError: ((String) -> Void)?

    init(
        descriptor: EditorDocumentDescriptor,
        initialContent: EditorInitialContent,
        autoScrollToBottom: Bool = false,
        saveRequestID: Int = 0,
        savedRevision: Int? = nil,
        onReady: (() -> Void)? = nil,
        onChange: ((Int) -> Void)? = nil,
        onSaveRequested: ((EditorSaveRequest) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.initialContent = initialContent
        self.autoScrollToBottom = autoScrollToBottom
        self.saveRequestID = saveRequestID
        self.savedRevision = savedRevision
        self.onReady = onReady
        self.onChange = onChange
        self.onSaveRequested = onSaveRequested
        self.onError = onError
    }

    var body: some View {
        RemoraEditorWebView(
            descriptor: descriptor,
            initialContent: initialContent,
            saveRequestID: saveRequestID,
            savedRevision: savedRevision,
            autoScrollToBottom: autoScrollToBottom,
            onReady: onReady,
            onChange: onChange,
            onEvent: nil,
            onTextChange: nil,
            onSaveRequested: onSaveRequested,
            onError: onError
        )
    }
}
