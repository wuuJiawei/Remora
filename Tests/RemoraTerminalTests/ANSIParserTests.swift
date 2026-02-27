import Foundation
import Testing
@testable import RemoraTerminal

struct ANSIParserTests {
    @Test
    func parserAppliesSGRAndText() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 5, columns: 20)

        parser.parse(Data("\u{001B}[31mA\u{001B}[0m".utf8), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].character == "A")
        #expect(line[0].attributes.foreground == .indexed(1))
        #expect(screen.activeAttributes == .default)
    }

    @Test
    func parserMovesCursor() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 5, columns: 20)

        parser.parse(Data("\u{001B}[2;3HX".utf8), into: screen)
        let line = screen.line(at: 1)
        #expect(line[2].character == "X")
    }

    @Test
    func parserHandlesHorizontalTabStops() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 16)

        parser.parse(Data("A\tB".utf8), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].character == "A")
        #expect(line[8].character == "B")
    }

    @Test
    func parserIgnoresOSCSequenceTerminatedByBEL() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 64)
        let data = Data("\u{001B}]0;root@example:/home\u{0007}root@example:/home# ".utf8)

        parser.parse(data, into: screen)

        let rendered = String(screen.line(at: 0).cells.map(\.character))
        #expect(!rendered.contains("0;root@example:/home"))
        #expect(rendered.contains("root@example:/home#"))
    }

    @Test
    func parserIgnoresOSCSequenceTerminatedByST() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 64)
        let data = Data("\u{001B}]0;root@example:/home\u{001B}\\root@example:/home# ".utf8)

        parser.parse(data, into: screen)

        let rendered = String(screen.line(at: 0).cells.map(\.character))
        #expect(!rendered.contains("0;root@example:/home"))
        #expect(rendered.contains("root@example:/home#"))
    }
}
