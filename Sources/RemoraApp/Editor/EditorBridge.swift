import Foundation

enum EditorBridgeMessageType: String, Decodable {
    case ready
    case changed
    case saveRequested
    case debug
    case error
}

struct EditorBridgeMessage: Decodable {
    let type: EditorBridgeMessageType
    let revision: Int?
    let message: String?
}

enum EditorDebugLog {
    static func log(_ message: @autoclosure () -> String) {
        print("[RemoraEditor] \(message())")
    }
}
