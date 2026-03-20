import AppKit
import Testing
@testable import RemoraApp

struct TerminalAIComposerTests {
    @Test
    func enterSubmitsWhenThereIsNoMarkedText() {
        let action = TerminalAIComposerSubmissionAction.resolve(
            selector: #selector(NSResponder.insertNewline(_:)),
            modifiers: [],
            hasMarkedText: false
        )

        #expect(action == .submit)
    }

    @Test
    func shiftEnterInsertsNewlineInsteadOfSubmitting() {
        let action = TerminalAIComposerSubmissionAction.resolve(
            selector: #selector(NSResponder.insertNewline(_:)),
            modifiers: [.shift],
            hasMarkedText: false
        )

        #expect(action == .insertLineBreak)
    }

    @Test
    func markedTextPreventsPrematureSubmitForIME() {
        let action = TerminalAIComposerSubmissionAction.resolve(
            selector: #selector(NSResponder.insertNewline(_:)),
            modifiers: [],
            hasMarkedText: true
        )

        #expect(action == .deferToSystem)
    }
}
