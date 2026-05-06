import Foundation

enum RemoraEditorInteractionMode {
    case editor
    case logViewer
}

struct EditorDocumentPayload: Encodable {
    let documentID: String
    let contentVersion: Int
    let text: String
    let path: String?
    let language: EditorLanguage
    let isEditable: Bool
    let lineWrapping: Bool
}

enum EditorTheme: String {
    case light
    case dark
}
