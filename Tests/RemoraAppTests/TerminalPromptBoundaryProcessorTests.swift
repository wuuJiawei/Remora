import Foundation
import Testing
@testable import RemoraApp

struct TerminalPromptBoundaryProcessorTests {
    @Test
    func buffersTrailingEscAcrossChunksForPromptMarker() {
        var processor = TerminalPromptBoundaryProcessor()

        let first = processor.process(Data("FAIL\u{1B}".utf8))
        #expect(first.count == 1)
        if case .output(let data)? = first.first {
            #expect(String(decoding: data, as: UTF8.self) == "FAIL")
        } else {
            Issue.record("Expected plain output token for initial chunk.")
        }

        let second = processor.process(Data("]133;A\u{7}PROMPT> ".utf8))
        #expect(second.count == 2)
        #expect(second[0] == .promptStart)
        if case .output(let data) = second[1] {
            #expect(String(decoding: data, as: UTF8.self) == "PROMPT> ")
        } else {
            Issue.record("Expected prompt text output token after prompt marker.")
        }
    }
}
