import AppKit
import Testing
@testable import RemoraApp

@MainActor
struct CommandComposerViewTests {
    @Test
    func commandComposerTextViewSubmitsOnInsertNewline() {
        let textView = CommandComposerTextView(frame: .zero)
        var submissions: [String] = []
        textView.onSubmit = { submissions.append($0) }
        textView.string = "echo hello"

        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(submissions == ["echo hello"])
        #expect(textView.string == "echo hello")
    }

    @Test
    func commandComposerTextViewInsertsLineBreakForInsertLineBreak() {
        let textView = CommandComposerTextView(frame: .zero)
        textView.string = "echo"
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        textView.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))

        #expect(textView.string == "echo\n")
        #expect(textView.selectedRange().location == 5)
    }

    @Test
    func commandComposerTextViewRoutesTabToShellCompletionHandler() {
        let textView = CommandComposerTextView(frame: .zero)
        var tabRequests = 0
        textView.onRequestShellCompletion = { tabRequests += 1 }
        textView.string = "cd /t"
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))

        #expect(tabRequests == 1)
        #expect(textView.string == "cd /t")
        #expect(textView.selectedRange().location == 5)
    }

    @Test
    func commandComposerTextViewUsesTerminalPalette() {
        let textView = CommandComposerTextView(frame: .zero)

        #expect(textView.backgroundColor == .clear)
        #expect(textView.drawsBackground == false)
        #expect(textView.textColor == NSColor(calibratedWhite: 0.9, alpha: 1))
        #expect(textView.insertionPointColor == NSColor(calibratedWhite: 0.9, alpha: 1))
    }
}
