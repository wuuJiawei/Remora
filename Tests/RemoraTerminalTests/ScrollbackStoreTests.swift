import Foundation
import Testing
@testable import RemoraTerminal

struct ScrollbackStoreTests {
    @Test
    func createsMultipleSegments() {
        let store = ScrollbackStore(segmentSize: 2)
        var line = TerminalLine(columns: 2)

        line[0] = TerminalCell(character: "a", attributes: .default)
        store.append(line)
        store.append(line)
        store.append(line)

        #expect(store.segmentCount() == 2)
        #expect(store.lineCount() == 3)
    }

    @Test
    func lineLookupReturnsExpectedRows() {
        let store = ScrollbackStore(segmentSize: 2)
        var first = TerminalLine(columns: 2)
        var second = TerminalLine(columns: 2)
        first[0] = TerminalCell(character: "a", attributes: .default)
        second[0] = TerminalCell(character: "b", attributes: .default)
        store.append(first)
        store.append(second)

        #expect(store.line(at: 0)?[0].character == "a")
        #expect(store.line(at: 1)?[0].character == "b")
        #expect(store.line(at: 99) == nil)
    }
}
