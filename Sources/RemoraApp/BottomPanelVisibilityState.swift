import Foundation

struct BottomPanelVisibilityState: Equatable {
    var terminal: Bool
    var fileManager: Bool

    mutating func toggleTerminal(fileManagerAvailable: Bool) {
        terminal.toggle()
        if !terminal && !fileManager && fileManagerAvailable {
            fileManager = true
            return
        }
        normalize(fileManagerAvailable: fileManagerAvailable)
    }

    mutating func toggleFileManager(fileManagerAvailable: Bool) {
        guard fileManagerAvailable else {
            fileManager = false
            terminal = true
            return
        }
        fileManager.toggle()
        if !terminal && !fileManager {
            terminal = true
            return
        }
        normalize(fileManagerAvailable: true)
    }

    mutating func normalize(fileManagerAvailable: Bool) {
        if !fileManagerAvailable {
            fileManager = false
        }
        if !terminal && !fileManager {
            if fileManagerAvailable {
                fileManager = true
            } else {
                terminal = true
            }
        }
    }

    func sessionShouldFillRemainingHeight(fileManagerAvailable: Bool) -> Bool {
        terminal || !fileManagerAvailable
    }

    func fileManagerShouldFillRemainingHeight(fileManagerAvailable: Bool) -> Bool {
        fileManagerAvailable && fileManager && !terminal
    }
}
