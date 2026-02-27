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
            return palette[Int(idx) % palette.count]
        }
    }

    private func drawRow(_ row: Int, screen: ScreenBuffer, context: CGContext, bounds: CGRect) {
        guard screen.validRowRange().contains(row) else { return }
        let line = screen.line(at: row)
        let baselineY = bounds.height - CGFloat(row + 1) * lineHeight + 2

        var currentAttrs: TerminalAttributes?
        var currentText = ""
        var runStartColumn = 0

        func flushRun(endColumn: Int) {
            guard let attrs = currentAttrs, !currentText.isEmpty else { return }
            let x = horizontalInset + CGFloat(runStartColumn) * cellWidth
            let y = baselineY
            let fg = color(for: attrs.foreground, isBackground: false)
            let bg = color(for: attrs.background, isBackground: true)

            let bgRect = CGRect(
                x: x,
                y: bounds.height - CGFloat(row + 1) * lineHeight,
                width: CGFloat(endColumn - runStartColumn) * cellWidth,
                height: lineHeight
            )
            bg.setFill()
            context.fill(bgRect)

            let attrString = NSAttributedString(string: currentText, attributes: [
                .font: attrs.bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font,
                .foregroundColor: fg,
                .underlineStyle: attrs.underline ? NSUnderlineStyle.single.rawValue : 0,
            ])
            attrString.draw(at: CGPoint(x: x, y: y))
        }

        for col in 0 ..< line.count {
            let cell = line[col]
            if currentAttrs == nil {
                currentAttrs = cell.attributes
                runStartColumn = col
            }

            if currentAttrs != cell.attributes {
                flushRun(endColumn: col)
                currentAttrs = cell.attributes
                currentText = ""
                runStartColumn = col
            }

            _ = glyphCache.attributedGlyph(
                for: cell,
                font: font,
                foreground: color(for: cell.attributes.foreground, isBackground: false),
                background: color(for: cell.attributes.background, isBackground: true)
            )
            currentText.append(cell.character)
        }

        flushRun(endColumn: line.count)
    }

    private func recalculateMetrics() {
        let sample = "W" as NSString
        let size = sample.size(withAttributes: [.font: font])
        cellWidth = ceil(size.width)
        lineHeight = ceil(size.height + 2)
    }

    private let palette: [NSColor] = [
        .black,
        .systemRed,
        .systemGreen,
        .systemYellow,
        .systemBlue,
        .systemPurple,
        .systemTeal,
        .white,
    ]
}
