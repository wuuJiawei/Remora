import AppKit
import Foundation

public final class TerminalInputMapper {
    public var applicationCursorKeysEnabled: Bool = false
    public var kittyKeyboardFlags: Int = 0

    public init() {}

    public func map(event: NSEvent) -> Data? {
        if useKittyProtocol,
           let kittySequence = mapKitty(event: event, eventType: event.isARepeat ? .repeatPress : .press)
        {
            return kittySequence
        }

        if let navigation = mapNavigation(event: event) {
            return navigation
        }

        switch event.keyCode {
        case 51: // delete
            return Data([0x7F])
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

    public func mapKeyUp(event: NSEvent) -> Data? {
        guard useKittyProtocol else { return nil }
        guard (kittyKeyboardFlags & KittyKeyboardFlag.reportEventTypes.rawValue) != 0 else { return nil }
        return mapKitty(event: event, eventType: .release)
    }

    public func map(command selector: Selector) -> Data? {
        if useKittyProtocol {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return kittyCSIU(keyCode: 13, modifiers: 0, eventType: .press)
            case #selector(NSResponder.insertTab(_:)):
                return kittyCSIU(keyCode: 9, modifiers: 0, eventType: .press)
            case #selector(NSResponder.deleteBackward(_:)):
                return kittyCSIU(keyCode: 127, modifiers: 0, eventType: .press)
            case #selector(NSResponder.cancelOperation(_:)):
                return kittyCSIU(keyCode: 27, modifiers: 0, eventType: .press)
            default:
                break
            }
        }

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

    // MARK: - Navigation

    private func mapNavigation(event: NSEvent) -> Data? {
        let modifier = xtermModifierValue(for: event)
        switch event.keyCode {
        case 123: // left
            return modifier == 0 ? data(leftSequence) : data("\u{1B}[1;\(modifier)D")
        case 124: // right
            return modifier == 0 ? data(rightSequence) : data("\u{1B}[1;\(modifier)C")
        case 125: // down
            return modifier == 0 ? data(downSequence) : data("\u{1B}[1;\(modifier)B")
        case 126: // up
            return modifier == 0 ? data(upSequence) : data("\u{1B}[1;\(modifier)A")
        case 115: // home
            return modifier == 0 ? data("\u{1B}[H") : data("\u{1B}[1;\(modifier)H")
        case 119: // end
            return modifier == 0 ? data("\u{1B}[F") : data("\u{1B}[1;\(modifier)F")
        case 116: // page up
            return modifier == 0 ? data("\u{1B}[5~") : data("\u{1B}[5;\(modifier)~")
        case 121: // page down
            return modifier == 0 ? data("\u{1B}[6~") : data("\u{1B}[6;\(modifier)~")
        case 117: // forward delete
            return modifier == 0 ? data("\u{1B}[3~") : data("\u{1B}[3;\(modifier)~")
        default:
            return nil
        }
    }

    // MARK: - Kitty Keyboard Protocol

    private enum KittyKeyboardFlag: Int {
        case disambiguateEscapeCodes = 1
        case reportEventTypes = 2
        case reportAlternateKeys = 4
        case reportAllKeysAsEscapeCodes = 8
        case reportAssociatedText = 16
    }

    private enum KittyEventType: Int {
        case press = 1
        case repeatPress = 2
        case release = 3
    }

    private var useKittyProtocol: Bool {
        kittyKeyboardFlags > 0
    }

    private func mapKitty(event: NSEvent, eventType: KittyEventType) -> Data? {
        let reportAllKeys = kittyKeyboardFlags & KittyKeyboardFlag.reportAllKeysAsEscapeCodes.rawValue != 0
        let reportEventTypes = kittyKeyboardFlags & KittyKeyboardFlag.reportEventTypes.rawValue != 0
        let disambiguate = kittyKeyboardFlags & KittyKeyboardFlag.disambiguateEscapeCodes.rawValue != 0

        if eventType == .release, !reportEventTypes {
            return nil
        }

        let isModifierKey = isModifierOnly(event.keyCode)
        if isModifierKey, !reportAllKeys {
            return nil
        }

        guard let keyCode = kittyKeyCode(for: event) else { return nil }
        let modifiers = kittyModifierValue(for: event)

        var shouldUseCSIU = false
        if reportAllKeys || reportEventTypes {
            shouldUseCSIU = true
        } else if disambiguate {
            if keyCode == 27 || keyCode == 127 || keyCode == 13 || keyCode == 9 || keyCode == 32 {
                shouldUseCSIU = true
            } else if modifiers > 0 {
                shouldUseCSIU = !isShiftPrintableOnly(event)
            }
        }

        guard shouldUseCSIU else { return nil }
        return kittyCSIU(keyCode: keyCode, modifiers: modifiers, eventType: eventType)
    }

    private func kittyCSIU(keyCode: Int, modifiers: Int, eventType: KittyEventType) -> Data {
        var sequence = "\u{1B}[\(keyCode)"
        let includeEventType = eventType != .press
        if modifiers > 0 || includeEventType {
            sequence += ";"
            sequence += modifiers > 0 ? "\(modifiers)" : "1"
            if includeEventType {
                sequence += ":\(eventType.rawValue)"
            }
        }
        sequence += "u"
        return data(sequence)
    }

    private func kittyKeyCode(for event: NSEvent) -> Int? {
        switch event.keyCode {
        case 53: // Escape
            return 27
        case 36, 76: // Return / keypad enter
            return 13
        case 48: // Tab
            return 9
        case 51: // Backspace
            return 127
        case 49: // Space
            return 32
        case 56: // Left shift
            return 57441
        case 60: // Right shift
            return 57447
        case 59: // Left control
            return 57442
        case 62: // Right control
            return 57448
        case 58: // Left option
            return 57443
        case 61: // Right option
            return 57449
        case 55: // Left command
            return 57444
        case 54: // Right command
            return 57450
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value
        if (65...90).contains(value) {
            return Int(value + 32)
        }
        return Int(value)
    }

    private func kittyModifierValue(for event: NSEvent) -> Int {
        var bits = 0
        let flags = event.modifierFlags.intersection([.shift, .option, .control, .command])
        if flags.contains(.shift) { bits |= 1 }
        if flags.contains(.option) { bits |= 2 }
        if flags.contains(.control) { bits |= 4 }
        if flags.contains(.command) { bits |= 8 }
        return bits > 0 ? bits + 1 : 0
    }

    private func xtermModifierValue(for event: NSEvent) -> Int {
        var bits = 0
        let flags = event.modifierFlags.intersection([.shift, .option, .control, .command])
        if flags.contains(.shift) { bits |= 1 }
        if flags.contains(.option) { bits |= 2 }
        if flags.contains(.control) { bits |= 4 }
        if flags.contains(.command) { bits |= 8 }
        return bits > 0 ? bits + 1 : 0
    }

    private func isModifierOnly(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62:
            return true
        default:
            return false
        }
    }

    private func isShiftPrintableOnly(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .option, .control, .command])
        guard flags == [.shift] else { return false }
        guard let chars = event.characters, chars.count == 1 else { return false }
        return true
    }
}
