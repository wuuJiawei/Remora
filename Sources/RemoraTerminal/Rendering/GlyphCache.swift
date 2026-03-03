import AppKit
import Foundation

public final class GlyphCache {
    private struct ColorSignature: Hashable {
        var red: UInt16
        var green: UInt16
        var blue: UInt16
        var alpha: UInt16
    }

    private struct Key: Hashable {
        var character: Character
        var fontName: String
        var fontSize: CGFloat
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var foreground: ColorSignature
        var background: ColorSignature
    }

    private var storage: [Key: NSAttributedString] = [:]

    public init() {}

    public func attributedGlyph(
        for cell: TerminalCell,
        font: NSFont,
        foreground: NSColor,
        background: NSColor
    ) -> NSAttributedString {
        let key = Key(
            character: cell.character,
            fontName: font.fontName,
            fontSize: font.pointSize,
            bold: cell.attributes.bold,
            italic: cell.attributes.italic,
            underline: cell.attributes.underline,
            foreground: colorSignature(foreground),
            background: colorSignature(background)
        )

        if let cached = storage[key] {
            return cached
        }

        let resolvedFont: NSFont = {
            var converted = font
            if cell.attributes.bold {
                converted = NSFontManager.shared.convert(converted, toHaveTrait: .boldFontMask)
            }
            if cell.attributes.italic {
                converted = NSFontManager.shared.convert(converted, toHaveTrait: .italicFontMask)
            }
            return converted
        }()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: foreground,
            .backgroundColor: background,
            .kern: 0,
            .ligature: 0,
            .underlineStyle: cell.attributes.underline ? NSUnderlineStyle.single.rawValue : 0,
        ]
        let value = NSAttributedString(string: String(cell.character), attributes: attrs)
        storage[key] = value
        return value
    }

    public func clear() {
        storage.removeAll(keepingCapacity: true)
    }

    private func colorSignature(_ color: NSColor) -> ColorSignature {
        let resolved = (color.usingColorSpace(.extendedSRGB) ?? color)
        return ColorSignature(
            red: quantize(resolved.redComponent),
            green: quantize(resolved.greenComponent),
            blue: quantize(resolved.blueComponent),
            alpha: quantize(resolved.alphaComponent)
        )
    }

    private func quantize(_ value: CGFloat) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        return UInt16((clamped * 65535).rounded())
    }
}
