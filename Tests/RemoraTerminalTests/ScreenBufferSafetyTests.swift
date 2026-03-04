import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RemoraTerminal

struct ScreenBufferSafetyTests {
    @Test
    func lineAtOutOfRangeReturnsBlankLine() {
        let screen = ScreenBuffer(rows: 3, columns: 5)

        let negative = screen.line(at: -1)
        let overflow = screen.line(at: 999)

        #expect(negative.count == 5)
        #expect(overflow.count == 5)
        #expect(negative[0].character == " ")
        #expect(overflow[0].character == " ")
    }

    @Test
    @MainActor
    func rendererIgnoresInvalidDirtyRows() {
        let screen = ScreenBuffer(rows: 2, columns: 8)
        let renderer = CoreTextTerminalRenderer()
        let width = max(Int(CGFloat(screen.columns) * renderer.cellWidth), 1)
        let height = max(Int(CGFloat(screen.rows) * renderer.lineHeight), 1)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to create drawing context")
            return
        }

        renderer.draw(
            screen: screen,
            in: context,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            dirtyRows: [-10, 0, 99]
        )
        let image = context.makeImage()
        #expect(image != nil)
        #expect(image?.width == width)
        #expect(image?.height == height)
    }

    @Test
    func alternateBufferResizeKeepsMainBufferWidthSafe() {
        let screen = ScreenBuffer(rows: 4, columns: 10)

        screen.enterAlternateBuffer()
        screen.resize(rows: 4, columns: 24)
        screen.leaveAlternateBuffer()

        // Regression: this write path previously crashed when restored main-buffer lines
        // still had stale widths after resize in alt buffer.
        screen.moveCursor(row: 0, column: 23)
        screen.put(character: "X")

        #expect(screen.line(at: 0).count == 24)
        #expect(screen.line(at: 0)[23].character == "X")
    }

    @Test
    func bufferRowMappingRespectsViewportOffset() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("one\r\ntwo\r\nthree\r\nfour".utf8), into: screen)
        screen.setViewportOffset(1)

        let startRow = screen.viewportStartBufferRow()
        let firstVisible = screen.line(at: 0)
        let mappedFirstVisible = screen.line(atBufferRow: startRow)

        #expect(screen.bufferRow(forViewportRow: 0) == startRow)
        #expect(firstVisible[0].character == mappedFirstVisible[0].character)
    }
}
