import Foundation

enum UnicodeCellWidth {
    static func width(of character: Character) -> Int {
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first {
            let value = scalar.value
            if (0x20 ... 0x7E).contains(value) {
                return 1
            }
            if isZeroWidth(scalar) {
                return 0
            }
            return isWide(scalar) ? 2 : 1
        }

        var sawVisibleScalar = false
        var result = 1

        for scalar in character.unicodeScalars {
            if isZeroWidth(scalar) {
                continue
            }
            sawVisibleScalar = true
            if isWide(scalar) {
                result = 2
            }
        }

        return sawVisibleScalar ? result : 0
    }

    private static func isZeroWidth(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return true
        case .control, .lineSeparator, .paragraphSeparator, .surrogate:
            return true
        default:
            break
        }

        let value = scalar.value
        if value == 0x200D || value == 0x200C || value == 0x00AD {
            return true
        }
        if (0xFE00 ... 0xFE0F).contains(value) || (0xE0100 ... 0xE01EF).contains(value) {
            return true
        }
        return false
    }

    private static func isWide(_ scalar: UnicodeScalar) -> Bool {
        if scalar.properties.isEmojiPresentation {
            return true
        }

        let value = scalar.value
        for range in wideRanges where range.contains(value) {
            return true
        }
        return false
    }

    // Based on the common wcwidth East Asian wide/full-width ranges.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100 ... 0x115F,
        0x231A ... 0x231B,
        0x2329 ... 0x232A,
        0x23E9 ... 0x23EC,
        0x23F0 ... 0x23F0,
        0x23F3 ... 0x23F3,
        0x25FD ... 0x25FE,
        0x2614 ... 0x2615,
        0x2648 ... 0x2653,
        0x267F ... 0x267F,
        0x2693 ... 0x2693,
        0x26A1 ... 0x26A1,
        0x26AA ... 0x26AB,
        0x26BD ... 0x26BE,
        0x26C4 ... 0x26C5,
        0x26CE ... 0x26CE,
        0x26D4 ... 0x26D4,
        0x26EA ... 0x26EA,
        0x26F2 ... 0x26F3,
        0x26F5 ... 0x26F5,
        0x26FA ... 0x26FA,
        0x26FD ... 0x26FD,
        0x2705 ... 0x2705,
        0x270A ... 0x270B,
        0x2728 ... 0x2728,
        0x274C ... 0x274C,
        0x274E ... 0x274E,
        0x2753 ... 0x2755,
        0x2757 ... 0x2757,
        0x2795 ... 0x2797,
        0x27B0 ... 0x27B0,
        0x27BF ... 0x27BF,
        0x2B1B ... 0x2B1C,
        0x2B50 ... 0x2B50,
        0x2B55 ... 0x2B55,
        0x2E80 ... 0x2FFB,
        0x3000 ... 0x303E,
        0x3041 ... 0x33FF,
        0x3400 ... 0x4DBF,
        0x4E00 ... 0xA4C6,
        0xA960 ... 0xA97C,
        0xAC00 ... 0xD7A3,
        0xF900 ... 0xFAFF,
        0xFE10 ... 0xFE19,
        0xFE30 ... 0xFE6B,
        0xFF01 ... 0xFF60,
        0xFFE0 ... 0xFFE6,
        0x1F004 ... 0x1F004,
        0x1F0CF ... 0x1F0CF,
        0x1F18E ... 0x1F18E,
        0x1F191 ... 0x1F19A,
        0x1F200 ... 0x1F251,
        0x1F300 ... 0x1FAFF,
        0x20000 ... 0x3FFFD,
    ]
}
