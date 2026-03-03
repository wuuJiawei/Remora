import AppKit
import Foundation

public final class TerminalInputMapper {
    public var applicationCursorKeysEnabled: Bool = false

    public init() {}

    public func map(event: NSEvent) -> Data? {
        switch event.keyCode {
        case 123: // left
            return data(leftSequence)
        case 124: // right
            return data(rightSequence)
        case 125: // down
            return data(downSequence)
        case 126: // up
            return data(upSequence)
        case 51: // delete
            return Data([0x7F])
        case 116: // page up
            return data("\u{1B}[5~")
        case 121: // page down
            return data("\u{1B}[6~")
        case 115: // home
            return data("\u{1B}[H")
        case 119: // end
            return data("\u{1B}[F")
        default:
            break
        }

        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let scalar = chars.unicodeScalars.first
        {
            let value = UInt8(scalar.value) & 0x1F
            return Data([value])
        }

        guard let chars = event.characters else { return nil }
        return Data(chars.utf8)
    }

    public func map(command selector: Selector) -> Data? {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            return data(upSequence)
        case #selector(NSResponder.moveDown(_:)):
            return data(downSequence)
        case #selector(NSResponder.moveRight(_:)):
            return data(rightSequence)
        case #selector(NSResponder.moveLeft(_:)):
            return data(leftSequence)
        case #selector(NSResponder.insertNewline(_:)):
            return Data([0x0D])
        case #selector(NSResponder.insertTab(_:)):
            return Data([0x09])
        case #selector(NSResponder.insertBacktab(_:)):
            return data("\u{1B}[Z")
        case #selector(NSResponder.deleteBackward(_:)):
            return Data([0x7F])
        case #selector(NSResponder.deleteForward(_:)):
            return data("\u{1B}[3~")
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            return Data([0x01]) // Ctrl-A
        case #selector(NSResponder.moveToEndOfLine(_:)):
            return Data([0x05]) // Ctrl-E
        case #selector(NSResponder.cancelOperation(_:)):
            return Data([0x03]) // Ctrl-C
        default:
            return nil
        }
    }

    private var upSequence: String {
        applicationCursorKeysEnabled ? "\u{1B}OA" : "\u{1B}[A"
    }

    private var downSequence: String {
        applicationCursorKeysEnabled ? "\u{1B}OB" : "\u{1B}[B"
    }

    private var rightSequence: String {
        applicationCursorKeysEnabled ? "\u{1B}OC" : "\u{1B}[C"
    }

    private var leftSequence: String {
        applicationCursorKeysEnabled ? "\u{1B}OD" : "\u{1B}[D"
    }

    private func data(_ value: String) -> Data {
        Data(value.utf8)
    }
}
