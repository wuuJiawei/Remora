import AppKit
import Foundation

public final class TerminalInputMapper {
    public var applicationCursorKeysEnabled: Bool = false
    public var kittyKeyboardFlags: Int = 0

    public init() {}

    public func mapLegacyControl(event: NSEvent) -> Data? {
        guard event.modifierFlags.contains(.control) else { return nil }
        guard !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) else { return nil }
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first
        else {
            return nil
        }
        let value = UInt8(scalar.value) & 0x1F
        return Data([value])
    }

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

        if let legacyControl = mapLegacyControl(event: event) {
            return legacyControl
        }

        guard let chars = event.characters else { return nil }
        return Data(chars.utf8)
    }

    public func mapKeyUp(event: NSEvent) -> Data? {
        guard useKittyProtocol else { return nil }
        guard (kittyKeyboardFlags & KittyKeyboardFlag.reportEventTypes.rawValue) != 0 else { return nil }
        return mapKitty(event: event, eventType: .release)
    }

    public func mapKittyKeyDown(event: NSEvent) -> Data? {
        guard useKittyProtocol else { return nil }
        return mapKitty(event: event, eventType: event.isARepeat ? .repeatPress : .press)
    }

    public func map(command selector: Selector) -> Data? {
        if useKittyProtocol {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return kittyCSIU(keyCode: 13, modifiers: 0, eventType: .press)
            case #selector(NSResponder.insertTab(_:)):
                return kittyCSIU(keyCode: 9, modifiers: 0, eventType: .press)
            case #selector(NSResponder.insertBacktab(_:)):
                return kittyCSIU(keyCode: 9, modifiers: 2, eventType: .press)
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
            if modifier == 0 {
                return applicationCursorKeysEnabled ? data("\u{1B}OH") : data("\u{1B}[H")
            }
            return data("\u{1B}[1;\(modifier)H")
        case 119: // end
            if modifier == 0 {
                return applicationCursorKeysEnabled ? data("\u{1B}OF") : data("\u{1B}[F")
            }
            return data("\u{1B}[1;\(modifier)F")
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

        if let letter = kittyCSILetter(for: event.keyCode) {
            return buildKittyCSILetter(letter: letter, modifiers: kittyModifierValue(for: event), eventType: eventType)
        }

        if let letter = kittySS3Letter(for: event.keyCode) {
            return buildKittySS3(letter: letter, modifiers: kittyModifierValue(for: event), eventType: eventType)
        }

        if let number = kittyCSITildeCode(for: event.keyCode) {
            return buildKittyCSITilde(number: number, modifiers: kittyModifierValue(for: event), eventType: eventType)
        }

        guard let keyCode = kittyKeyCode(for: event) else { return nil }
        let modifiers = kittyModifierValue(for: event)
        let isFunctionalKey = isKittyFunctionalKey(event.keyCode) || kittyNumpadKeyCode(for: event.keyCode) != nil

        var shouldUseCSIU = false
        if reportAllKeys || reportEventTypes {
            shouldUseCSIU = true
        } else if disambiguate {
            if keyCode == 27 || keyCode == 127 || keyCode == 13 || keyCode == 9 || keyCode == 32 {
                shouldUseCSIU = true
            } else if isFunctionalKey {
                shouldUseCSIU = true
            } else if modifiers > 0 {
                shouldUseCSIU = !isShiftPrintableOnly(event)
            }
        }

        guard shouldUseCSIU else { return nil }
        return kittyCSIU(
            event: event,
            keyCode: keyCode,
            modifiers: modifiers,
            eventType: eventType,
            isFunctionalKey: isFunctionalKey,
            isModifierKey: isModifierKey
        )
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

    private func kittyCSIU(
        event: NSEvent,
        keyCode: Int,
        modifiers: Int,
        eventType: KittyEventType,
        isFunctionalKey: Bool,
        isModifierKey: Bool
    ) -> Data {
        let reportEventTypes = (kittyKeyboardFlags & KittyKeyboardFlag.reportEventTypes.rawValue) != 0
        let reportAlternateKeys = (kittyKeyboardFlags & KittyKeyboardFlag.reportAlternateKeys.rawValue) != 0
        let reportAssociatedText = (kittyKeyboardFlags & KittyKeyboardFlag.reportAssociatedText.rawValue) != 0

        var sequence = "\u{1B}[\(keyCode)"

        if reportAlternateKeys,
           event.modifierFlags.contains(.shift),
           !isFunctionalKey,
           !isModifierKey,
           let shifted = scalarFromCharacters(event.characters)
        {
            sequence += ":\(shifted.value)"
        }

        let associatedTextCode: UInt32? = {
            guard reportAssociatedText else { return nil }
            guard eventType != .release else { return nil }
            guard !isFunctionalKey, !isModifierKey else { return nil }
            guard !event.modifierFlags.contains(.control) else { return nil }
            return scalarFromCharacters(event.characters)?.value
        }()

        let needsEventType = reportEventTypes && eventType != .press && (eventType == .release || associatedTextCode == nil)

        if modifiers > 0 || needsEventType || associatedTextCode != nil {
            sequence += ";"
            if modifiers > 0 {
                sequence += "\(modifiers)"
            } else if needsEventType {
                sequence += "1"
            }
            if needsEventType {
                sequence += ":\(eventType.rawValue)"
            }
        }

        if let associatedTextCode {
            sequence += ";\(associatedTextCode)"
        }

        sequence += "u"
        return data(sequence)
    }

    private func kittyKeyCode(for event: NSEvent) -> Int? {
        if let code = kittyNumpadKeyCode(for: event.keyCode) {
            return code
        }

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
        case 57: // Caps Lock
            return 57358
        case 107: // F14
            return 57377
        case 113: // F15
            return 57378
        case 106: // F16
            return 57379
        case 64: // F17
            return 57380
        case 79: // F18
            return 57381
        case 80: // F19
            return 57382
        case 90: // F20
            return 57383
        case 105: // F13
            return 57376
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

    private func kittyCSILetter(for keyCode: UInt16) -> Character? {
        switch keyCode {
        case 126: return "A" // Arrow up
        case 125: return "B" // Arrow down
        case 124: return "C" // Arrow right
        case 123: return "D" // Arrow left
        case 115: return "H" // Home
        case 119: return "F" // End
        default: return nil
        }
    }

    private func kittySS3Letter(for keyCode: UInt16) -> Character? {
        switch keyCode {
        case 122: return "P" // F1
        case 120: return "Q" // F2
        case 99: return "R" // F3
        case 118: return "S" // F4
        default: return nil
        }
    }

    private func kittyCSITildeCode(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 114: return 2 // Insert (Help on mac keyboards)
        case 117: return 3 // Delete
        case 116: return 5 // PageUp
        case 121: return 6 // PageDown
        case 96: return 15 // F5
        case 97: return 17 // F6
        case 98: return 18 // F7
        case 100: return 19 // F8
        case 101: return 20 // F9
        case 109: return 21 // F10
        case 103: return 23 // F11
        case 111: return 24 // F12
        default: return nil
        }
    }

    private func buildKittyCSILetter(letter: Character, modifiers: Int, eventType: KittyEventType) -> Data {
        let includeEventType = (kittyKeyboardFlags & KittyKeyboardFlag.reportEventTypes.rawValue) != 0 && eventType != .press
        if modifiers == 0, !includeEventType {
            return data("\u{1B}[\(letter)")
        }

        var sequence = "\u{1B}[1;\(modifiers > 0 ? String(modifiers) : "1")"
        if includeEventType {
            sequence += ":\(eventType.rawValue)"
        }
        sequence += "\(letter)"
        return data(sequence)
    }

    private func buildKittySS3(letter: Character, modifiers: Int, eventType: KittyEventType) -> Data {
        let includeEventType = (kittyKeyboardFlags & KittyKeyboardFlag.reportEventTypes.rawValue) != 0 && eventType != .press
        if modifiers == 0, !includeEventType {
            return data("\u{1B}O\(letter)")
        }

        var sequence = "\u{1B}[1;\(modifiers > 0 ? String(modifiers) : "1")"
        if includeEventType {
            sequence += ":\(eventType.rawValue)"
        }
        sequence += "\(letter)"
        return data(sequence)
    }

    private func buildKittyCSITilde(number: Int, modifiers: Int, eventType: KittyEventType) -> Data {
        let includeEventType = (kittyKeyboardFlags & KittyKeyboardFlag.reportEventTypes.rawValue) != 0 && eventType != .press
        var sequence = "\u{1B}[\(number)"
        if modifiers > 0 || includeEventType {
            sequence += ";\(modifiers > 0 ? String(modifiers) : "1")"
            if includeEventType {
                sequence += ":\(eventType.rawValue)"
            }
        }
        sequence += "~"
        return data(sequence)
    }

    private func kittyNumpadKeyCode(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 82: return 57399  // KP_0
        case 83: return 57400  // KP_1
        case 84: return 57401  // KP_2
        case 85: return 57402  // KP_3
        case 86: return 57403  // KP_4
        case 87: return 57404  // KP_5
        case 88: return 57405  // KP_6
        case 89: return 57406  // KP_7
        case 91: return 57407  // KP_8
        case 92: return 57408  // KP_9
        case 65: return 57409  // KP_Decimal
        case 75: return 57410  // KP_Divide
        case 67: return 57411  // KP_Multiply
        case 78: return 57412  // KP_Subtract
        case 69: return 57413  // KP_Add
        case 76: return 57414  // KP_Enter
        case 81: return 57415  // KP_Equal
        default: return nil
        }
    }

    private func isKittyFunctionalKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 53, 36, 48, 49, 51, 57: // Escape/Enter/Tab/Space/Backspace/CapsLock
            return true
        case 105, 107, 113, 106, 64, 79, 80, 90: // F13-F20
            return true
        default:
            return false
        }
    }

    private func scalarFromCharacters(_ value: String?) -> Unicode.Scalar? {
        guard let value, value.count == 1 else { return nil }
        return value.unicodeScalars.first
    }
}
