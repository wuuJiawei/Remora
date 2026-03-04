import AppKit
import CoreText
import Testing
@testable import RemoraTerminal

struct CoreTextTerminalRendererTests {
    @Test
    func baselineOffsetUsesFontDescentFloor() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let renderer = CoreTextTerminalRenderer(font: font)
        let ctFont = font as CTFont
        let descent = ceil(CTFontGetDescent(ctFont))

        #expect(renderer.baselineOffsetForTesting >= descent)
        #expect(renderer.baselineOffsetForTesting < renderer.lineHeight)
    }
}
