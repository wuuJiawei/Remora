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
    func parserMovesCursorToAbsoluteColumn() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 10)

        parser.parse(Data("abc\u{001B}[6GZ".utf8), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].character == "a")
        #expect(line[1].character == "b")
        #expect(line[2].character == "c")
        #expect(line[5].character == "Z")
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
    func parserAppliesOSC8HyperlinkMetadata() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 64)
        let data = Data("\u{001B}]8;;https://example.com\u{0007}hello\u{001B}]8;;\u{0007}".utf8)

        parser.parse(data, into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].character == "h")
        #expect(line[0].hyperlink == "https://example.com")
        #expect(screen.activeHyperlink == nil)
    }

    @Test
    func parserParsesOSC8AcrossChunkBoundaries() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 64)
        let payload = Data("\u{001B}]8;;https://example.com\u{001B}\\ab\u{001B}]8;;\u{001B}\\".utf8)

        parser.parse(payload.prefix(7), into: screen)
        parser.parse(payload.dropFirst(7).prefix(9), into: screen)
        parser.parse(payload.dropFirst(16), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].character == "a")
        #expect(line[0].hyperlink == "https://example.com")
        #expect(line[1].character == "b")
        #expect(line[1].hyperlink == "https://example.com")
        #expect(screen.activeHyperlink == nil)
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

    @Test
    func parserDoesNotTreatPrivateUAsRestoreCursor() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 4, columns: 20)

        parser.parse(Data("\u{001B}[1;1HABCD".utf8), into: screen)
        parser.parse(Data("\u{001B}[2;1HWXYZ".utf8), into: screen)
        parser.parse(Data("\u{001B}[?u".utf8), into: screen)
        parser.parse(Data("!".utf8), into: screen)

        let row0 = rstrip(String(screen.line(at: 0).cells.map(\.character)))
        let row1 = rstrip(String(screen.line(at: 1).cells.map(\.character)))

        #expect(row0 == "ABCD")
        #expect(row1 == "WXYZ!")
    }

    @Test
    func parserAppliesExtendedSGRColors() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("\u{001B}[38;2;255;136;0;48;5;24mX".utf8), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].attributes.foreground == .trueColor(255, 136, 0))
        #expect(line[0].attributes.background == .indexed(24))
    }

    @Test
    func parserAppliesBrightANSIColors() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("\u{001B}[93;104mX".utf8), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].attributes.foreground == .indexed(11))
        #expect(line[0].attributes.background == .indexed(12))
    }

    @Test
    func parserAppliesInverseDimAndItalicStyles() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("\u{001B}[2;3;7mX".utf8), into: screen)
        let styled = screen.line(at: 0)[0].attributes
        #expect(styled.dim == true)
        #expect(styled.italic == true)
        #expect(styled.inverse == true)

        parser.parse(Data("\u{001B}[22;23;27mY".utf8), into: screen)
        let reset = screen.line(at: 0)[1].attributes
        #expect(reset.dim == false)
        #expect(reset.bold == false)
        #expect(reset.italic == false)
        #expect(reset.inverse == false)
    }

    @Test
    func parserClearScreenKeepsActiveAttributes() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 8)

        parser.parse(Data("\u{001B}[31;44m\u{001B}[2JX".utf8), into: screen)

        let cell = screen.line(at: 0)[0]
        #expect(cell.character == "X")
        #expect(cell.attributes.foreground == .indexed(1))
        #expect(cell.attributes.background == .indexed(4))
        #expect(screen.activeAttributes.foreground == .indexed(1))
        #expect(screen.activeAttributes.background == .indexed(4))
    }

    @Test
    func parserTracksFocusReportingMode() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("\u{001B}[?1004h".utf8), into: screen)
        #expect(parser.focusReportingEnabled == true)

        parser.parse(Data("\u{001B}[?1004l".utf8), into: screen)
        #expect(parser.focusReportingEnabled == false)
    }

    @Test
    func parserTracksSGRMouseMode() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("\u{001B}[?1006h".utf8), into: screen)
        #expect(parser.sgrMouseModeEnabled == true)

        parser.parse(Data("\u{001B}[?1006l".utf8), into: screen)
        #expect(parser.sgrMouseModeEnabled == false)
    }

    @Test
    func parserHandlesKittyKeyboardSetPushPopAndQuery() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)
        var queriedFlags: [Int] = []
        parser.onKittyKeyboardQuery = { queriedFlags.append($0) }

        parser.parse(Data("\u{001B}[=7;1u".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 7)

        parser.parse(Data("\u{001B}[>2u".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 2)

        parser.parse(Data("\u{001B}[<u".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 7)

        parser.parse(Data("\u{001B}[?u".utf8), into: screen)
        #expect(queriedFlags == [7])
    }

    @Test
    func parserSwapsKittyKeyboardFlagsAcrossAlternateBuffer() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 10)

        parser.parse(Data("\u{001B}[=3;1u".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 3)

        parser.parse(Data("\u{001B}[?1049h".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 0)
        #expect(screen.isAlternateBuffer == true)

        parser.parse(Data("\u{001B}[=5;1u".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 5)

        parser.parse(Data("\u{001B}[?1049l".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 3)
        #expect(screen.isAlternateBuffer == false)

        parser.parse(Data("\u{001B}[?1049h".utf8), into: screen)
        #expect(parser.kittyKeyboardFlags == 5)
    }

    @Test
    func parserHandlesReverseIndexInScrollRegion() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 5, columns: 4)
        parser.parse(Data("1\r\n2\r\n3\r\n4\r\n5".utf8), into: screen)

        parser.parse(Data("\u{001B}[2;4r".utf8), into: screen)
        parser.parse(Data("\u{001B}[2;1H".utf8), into: screen)
        parser.parse(Data("\u{001B}M".utf8), into: screen)
        parser.parse(Data("\u{001B}[r".utf8), into: screen)

        let row0 = rstrip(String(screen.line(at: 0).cells.map(\.character)))
        let row1 = rstrip(String(screen.line(at: 1).cells.map(\.character)))
        let row2 = rstrip(String(screen.line(at: 2).cells.map(\.character)))
        let row3 = rstrip(String(screen.line(at: 3).cells.map(\.character)))
        let row4 = rstrip(String(screen.line(at: 4).cells.map(\.character)))

        #expect(row0 == "1")
        #expect(row1.isEmpty)
        #expect(row2 == "2")
        #expect(row3 == "3")
        #expect(row4 == "5")
    }

    @Test
    func parserUsesDelayedAutoWrapAtLineEnd() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 4)

        parser.parse(Data("ABCD".utf8), into: screen)
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorColumn == 3)

        parser.parse(Data("E".utf8), into: screen)
        let row0 = rstrip(String(screen.line(at: 0).cells.map(\.character)))
        let row1 = rstrip(String(screen.line(at: 1).cells.map(\.character)))
        #expect(row0 == "ABCD")
        #expect(row1 == "E")
    }

    @Test
    func carriageReturnCancelsPendingAutoWrap() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 4)

        parser.parse(Data("ABCD\rZ".utf8), into: screen)
        let row0 = rstrip(String(screen.line(at: 0).cells.map(\.character)))
        let row1 = rstrip(String(screen.line(at: 1).cells.map(\.character)))
        #expect(row0 == "ZBCD")
        #expect(row1.isEmpty)
    }

    @Test
    func backspaceDoesNotEraseCharacter() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("AB\u{0008}C".utf8), into: screen)

        let row0 = rstrip(String(screen.line(at: 0).cells.map(\.character)))
        #expect(row0 == "AC")
    }

    @Test
    func resetScrollRegionHomesCursor() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 4, columns: 8)

        parser.parse(Data("\u{001B}[3;5H".utf8), into: screen)
        parser.parse(Data("\u{001B}[r".utf8), into: screen)

        #expect(screen.cursorRow == 0)
        #expect(screen.cursorColumn == 0)
    }

    @Test
    func parserTracksWideCharacterCells() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("A你B".utf8), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].character == "A")
        #expect(line[1].character == "你")
        #expect(line[1].displayWidth == 2)
        #expect(line[2].displayWidth == 0)
        #expect(line[3].character == "B")
    }

    @Test
    func parserWrapsBeforeWideCharacterAtLastColumn() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 3, columns: 4)

        parser.parse(Data("ABC你Z".utf8), into: screen)

        let row0 = screen.line(at: 0)
        let row1 = screen.line(at: 1)
        #expect(rstrip(String(row0.cells.map(\.character))) == "ABC")
        #expect(row1[0].character == "你")
        #expect(row1[0].displayWidth == 2)
        #expect(row1[1].displayWidth == 0)
        #expect(row1[2].character == "Z")
    }

    @Test
    func parserKeepsCombiningMarkInSingleCell() {
        let parser = ANSIParser()
        let screen = ScreenBuffer(rows: 2, columns: 8)

        parser.parse(Data("e\u{0301}x".utf8), into: screen)

        let line = screen.line(at: 0)
        #expect(line[0].displayWidth == 1)
        #expect(line[1].character == "x")
        #expect(screen.cursorColumn == 2)
    }

    private func rstrip(_ text: String) -> String {
        var output = text
        while output.last == " " {
            output.removeLast()
        }
        return output
    }
}
