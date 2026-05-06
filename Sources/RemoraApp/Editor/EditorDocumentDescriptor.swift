import Foundation

struct EditorDocumentDescriptor: Equatable {
    let id: String
    let path: String?
    let language: EditorLanguage
    let isEditable: Bool
    let lineWrapping: Bool
}

struct EditorInitialContent: Equatable {
    let documentID: String
    let text: String
    let contentVersion: Int
}
