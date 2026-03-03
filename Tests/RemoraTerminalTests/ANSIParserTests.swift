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

    @Test
    func parserDecodesUTF8AcrossChunkBoundaries() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data([0xE2]), into: screen)
        parser.parse(Data([0x94]), into: screen)
        parser.parse(Data([0x80]), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].character == "─")
    }

    @Test
    func parserSwallowsPrivateModeSequencesWithRandomChunking() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 6, columns: 64)
        let payload = Data(
            (
                "\u{001B}[?2026h" +
                "\u{001B}[?25l" +
                "\u{001B}[1;1H❯    Yes, I trust this folder" +
                "\u{001B}[2;1H     No, exit" +
                "\u{001B}[?2026l"
            ).utf8
        )

        var cursor = 0
        var seed: UInt64 = 0xC0DEC0DE
        while cursor < payload.count {
            seed = seed &* 6364136223846793005 &+ 1
            let chunkLength = Int(seed % 7) + 1
            let end = min(payload.count, cursor + chunkLength)
            parser.parse(payload.subdata(in: cursor ..< end), into: screen)
            cursor = end
        }

        let line0 = rstrip(String(screen.line(at: 0).cells.map(\.character)))
        let line1 = rstrip(String(screen.line(at: 1).cells.map(\.character)))
        let combined = line0 + "\n" + line1

        #expect(line0 == "❯    Yes, I trust this folder")
        #expect(line1 == "     No, exit")
        #expect(!combined.contains("026-"))
        #expect(!combined.contains("?25l"))
        #expect(screen.isCursorVisible == false)
        #expect(screen.isSynchronizedUpdate == false)
    }

    @Test
    func parserTracksApplicationCursorKeysMode() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("\u{001B}[?1h".utf8), into: screen)
        #expect(parser.applicationCursorKeysEnabled == true)

        parser.parse(Data("\u{001B}[?1l".utf8), into: screen)
        #expect(parser.applicationCursorKeysEnabled == false)
    }

    @Test
    func parserEndsSynchronizedUpdateWithFullDirtyRefresh() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 8)
        _ = screen.consumeDirtyRows()

        parser.parse(Data("\u{001B}[?2026h".utf8), into: screen)
        parser.parse(Data("abc".utf8), into: screen)
        #expect(screen.isSynchronizedUpdate == true)

        parser.parse(Data("\u{001B}[?2026l".utf8), into: screen)
        let dirtyRows = screen.consumeDirtyRows()
        #expect(screen.isSynchronizedUpdate == false)
        #expect(dirtyRows == Set(0 ..< screen.rows))
    }

    @Test
    func parserAppliesScrollingRegionAndScrollUp() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 5, columns: 8)
        parser.parse(Data("1\r\n2\r\n3\r\n4\r\n5".utf8), into: screen)

        parser.parse(Data("\u{001B}[1;3r".utf8), into: screen)
        parser.parse(Data("\u{001B}[3;1H".utf8), into: screen)
        parser.parse(Data("\u{001B}[1S".utf8), into: screen)
        parser.parse(Data("\u{001B}[r".utf8), into: screen)

        let row0 = rstrip(String(screen.line(at: 0).cells.map(\.character)))
        let row1 = rstrip(String(screen.line(at: 1).cells.map(\.character)))
        let row2 = rstrip(String(screen.line(at: 2).cells.map(\.character)))
        let row3 = rstrip(String(screen.line(at: 3).cells.map(\.character)))
        let row4 = rstrip(String(screen.line(at: 4).cells.map(\.character)))

        #expect(row0 == "2")
        #expect(row1 == "3")
        #expect(row2.isEmpty)
        #expect(row3 == "4")
        #expect(row4 == "5")
    }

    private func rstrip(_ text: String) -> String {
        var output = text
        while output.last == " " {
            output.removeLast()
        }
        return output
    }
}
