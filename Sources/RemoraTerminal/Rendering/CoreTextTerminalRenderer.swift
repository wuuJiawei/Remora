import AppKit
import CoreText
import Foundation

public final class CoreTextTerminalRenderer {
    public var font: NSFont {
        didSet {
            recalculateMetrics()
            glyphCache.clear()
        }
    }

    public private(set) var cellWidth: CGFloat = 8
    public private(set) var lineHeight: CGFloat = 16
    public var horizontalInset: CGFloat = 10

    private let glyphCache = GlyphCache()
    private var baselineOffset: CGFloat = 2

    var baselineOffsetForTesting: CGFloat {
        baselineOffset
    }

    public init(font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
        self.font = font
        recalculateMetrics()
    }

    public func draw(
        screen: ScreenBuffer,
        in context: CGContext,
        bounds: CGRect,
        dirtyRows: Set<Int>
    ) {
        let validRows = Set(screen.validRowRange())
        let rows = dirtyRows.isEmpty ? validRows : dirtyRows.intersection(validRows)
        if dirtyRows.isEmpty {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)
        }
        for row in rows.sorted() {
            drawRow(row, screen: screen, context: context, bounds: bounds)
        }
    }

    public func color(for terminalColor: TerminalColor, isBackground: Bool) -> NSColor {
        switch terminalColor {
        case .default:
            return isBackground ? NSColor.black : NSColor(calibratedWhite: 0.9, alpha: 1)
        case .indexed(let idx):
            return indexedColor(idx)
        case .trueColor(let red, let green, let blue):
            return NSColor(
                calibratedRed: CGFloat(red) / 255.0,
                green: CGFloat(green) / 255.0,
                blue: CGFloat(blue) / 255.0,
                alpha: 1
            )
        }
    }

    private func drawRow(_ row: Int, screen: ScreenBuffer, context: CGContext, bounds: CGRect) {
        guard screen.validRowRange().contains(row) else { return }
        let line = screen.line(at: row)
        let rowY = bounds.height - CGFloat(row + 1) * lineHeight
        let baselineY = rowY + baselineOffset

        for col in 0 ..< line.count {
            let cell = line[col]
            let x = horizontalInset + CGFloat(col) * cellWidth
            var fg = color(for: cell.attributes.foreground, isBackground: false)
            var bg = color(for: cell.attributes.background, isBackground: true)
            if cell.attributes.inverse {
                swap(&fg, &bg)
            }
            if cell.attributes.dim {
                fg = fg.withAlphaComponent(0.65)
            }

            context.setFillColor(bg.cgColor)
            context.fill(CGRect(x: x, y: rowY, width: cellWidth, height: lineHeight))

            if cell.displayWidth == 0 || cell.character == " " {
                continue
            }

            let glyph = glyphCache.attributedGlyph(
                for: cell,
                font: font,
                foreground: fg,
                background: bg
            )
            glyph.draw(at: CGPoint(x: x, y: baselineY))
        }
    }

    private func recalculateMetrics() {
        let ctFont = font as CTFont
        let ascent = ceil(CTFontGetAscent(ctFont))
        let descent = ceil(CTFontGetDescent(ctFont))
        let leading = ceil(CTFontGetLeading(ctFont))

        let sample = "W" as NSString
        let size = sample.size(withAttributes: [.font: font])
        cellWidth = max(1, ceil(size.width))

        let contentHeight = max(1, ascent + descent)
        let naturalLineHeight = max(contentHeight + leading, ceil(font.boundingRectForFont.height))
        lineHeight = max(1, ceil(naturalLineHeight + 2))

        let verticalPadding = max(0, lineHeight - contentHeight)
        baselineOffset = max(1, floor(descent + (verticalPadding * 0.5)))
    }

    private func indexedColor(_ index: UInt8) -> NSColor {
        let idx = Int(index)
        if idx < 16 {
            return ansi16Palette[idx]
        }
        if idx < 232 {
            let cube = idx - 16
            let red = cube / 36
            let green = (cube % 36) / 6
            let blue = cube % 6
            return NSColor(
                calibratedRed: colorCubeComponent(red),
                green: colorCubeComponent(green),
                blue: colorCubeComponent(blue),
                alpha: 1
            )
        }
        let grayscale = CGFloat(8 + (idx - 232) * 10) / 255.0
        return NSColor(calibratedRed: grayscale, green: grayscale, blue: grayscale, alpha: 1)
    }

    private func colorCubeComponent(_ value: Int) -> CGFloat {
        if value == 0 { return 0 }
        return CGFloat(55 + value * 40) / 255.0
    }

    private let ansi16Palette: [NSColor] = [
        NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1),
        NSColor(calibratedRed: 0.804, green: 0.200, blue: 0.200, alpha: 1),
        NSColor(calibratedRed: 0.525, green: 0.600, blue: 0.000, alpha: 1),
        NSColor(calibratedRed: 0.745, green: 0.600, blue: 0.000, alpha: 1),
        NSColor(calibratedRed: 0.200, green: 0.400, blue: 0.800, alpha: 1),
        NSColor(calibratedRed: 0.600, green: 0.400, blue: 0.800, alpha: 1),
        NSColor(calibratedRed: 0.200, green: 0.600, blue: 0.600, alpha: 1),
        NSColor(calibratedRed: 0.800, green: 0.800, blue: 0.800, alpha: 1),
        NSColor(calibratedRed: 0.337, green: 0.341, blue: 0.325, alpha: 1),
        NSColor(calibratedRed: 0.937, green: 0.161, blue: 0.161, alpha: 1),
        NSColor(calibratedRed: 0.729, green: 0.839, blue: 0.102, alpha: 1),
        NSColor(calibratedRed: 0.984, green: 0.831, blue: 0.176, alpha: 1),
        NSColor(calibratedRed: 0.443, green: 0.624, blue: 0.902, alpha: 1),
        NSColor(calibratedRed: 0.749, green: 0.498, blue: 0.902, alpha: 1),
        NSColor(calibratedRed: 0.278, green: 0.729, blue: 0.729, alpha: 1),
        NSColor(calibratedRed: 0.933, green: 0.933, blue: 0.933, alpha: 1),
    ]
}
