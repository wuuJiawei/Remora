import Foundation

enum EditorEvent: Equatable {
    case ready
    case changed(revision: Int)
    case error(String)
}

struct EditorSaveRequest: Equatable {
    let revision: Int
    let text: String
}
