import SwiftUI

enum ContextMenuIconCatalog {
    static let addConnection = "plus"
    static let newSession = "plus"
    static let rename = "pencil"
    static let splitHorizontal = "rectangle.split.2x1"
    static let splitVertical = "rectangle.split.1x2"
    static let reconnect = "arrow.clockwise"
    static let disconnect = "xmark.circle"
    static let closeCurrent = "xmark"
    static let closeAll = "xmark.square"
    static let closeInactive = "square.stack.3d.down.right.slash"
    static let closeLeft = "sidebar.left"
    static let closeRight = "sidebar.right"
    static let expand = "chevron.down"
    static let collapse = "chevron.right"
    static let editGroup = "square.and.pencil"
    static let export = "square.and.arrow.up"
    static let delete = "trash"
    static let editConnection = "square.and.pencil"
    static let copy = "doc.on.doc"
    static let manageQuickCommands = "terminal"
    static let refresh = "arrow.clockwise"
    static let newFile = "doc.badge.plus"
    static let newFolder = "folder.badge.plus"
    static let paste = "doc.on.clipboard"
    static let upload = "arrow.up.circle"
    static let compress = "archivebox"
    static let extract = "archivebox.fill"
    static let download = "arrow.down.circle"
    static let moveTo = "folder"
    static let liveView = "waveform.path.ecg"
    static let edit = "doc.text"
    static let copyPath = "link"
    static let properties = "slider.horizontal.3"
    static let permissions = "lock.shield"
    static let reveal = "folder"
}

@ViewBuilder
func contextMenuButton(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
    if let role {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
    } else {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}
