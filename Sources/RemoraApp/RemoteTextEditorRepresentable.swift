import SwiftUI

struct RemoteTextEditorRepresentable: View {
    private let descriptor: EditorDocumentDescriptor
    private let initialContent: EditorInitialContent
    private let saveRequestID: Int
    private let savedRevision: Int?
    private let onChange: ((Int) -> Void)?
    private let onSaveRequested: ((EditorSaveRequest) -> Void)?
    private let onError: ((String) -> Void)?

    init(
        descriptor: EditorDocumentDescriptor,
        initialContent: EditorInitialContent,
        saveRequestID: Int = 0,
        savedRevision: Int? = nil,
        onChange: ((Int) -> Void)? = nil,
        onSaveRequested: ((EditorSaveRequest) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.initialContent = initialContent
        self.saveRequestID = saveRequestID
        self.savedRevision = savedRevision
        self.onChange = onChange
        self.onSaveRequested = onSaveRequested
        self.onError = onError
    }

    var body: some View {
        RemoraEditorView(
            descriptor: descriptor,
            initialContent: initialContent,
            autoScrollToBottom: false,
            saveRequestID: saveRequestID,
            savedRevision: savedRevision,
            onReady: nil,
            onChange: onChange,
            onSaveRequested: onSaveRequested,
            onError: onError
        )
    }
}
