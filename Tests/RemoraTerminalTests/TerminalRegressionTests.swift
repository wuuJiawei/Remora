import Foundation
import Testing
@testable import RemoraTerminal

struct TerminalRegressionTests {
    @Test
    func clearScreenResetsVisibleBuffer() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 8)

        parser.parse(Data("abc\r\ndef\r\n".utf8), into: screen)
        parser.parse(Data("\u{001B}[2J\u{001B}[H".utf8), into: screen)

        let line0 = screen.line(at: 0)
        #expect(line0[0].character == " ")
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorColumn == 0)
    }

    @Test
    func scrollbackAppendsOverflowLines() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8, scrollbackSegmentSize: 1)

        parser.parse(Data("row1\r\nrow2\r\nrow3\r\n".utf8), into: screen)

        #expect(screen.scrollback.lineCount() >= 1)
        #expect(screen.scrollback.segmentCount() >= 1)
    }

    @Test
    func viewportOffsetShowsScrollbackLines() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("one\r\ntwo\r\nthree\r\nfour".utf8), into: screen)

        func lineText(_ row: Int) -> String {
            var text = String(screen.line(at: row).cells.map(\.character))
            while text.last == " " {
                text.removeLast()
            }
            return text
        }

        let bottomBefore = [lineText(0), lineText(1)]
        #expect(bottomBefore[0] == "three")
        #expect(bottomBefore[1] == "four")

        screen.setViewportOffset(1)
        let scrolled = [lineText(0), lineText(1)]
        #expect(scrolled[0] == "two")
        #expect(scrolled[1] == "three")
    }
}
