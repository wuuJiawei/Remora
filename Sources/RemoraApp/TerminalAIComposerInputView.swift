import AppKit
import SwiftUI

enum TerminalAIComposerSubmissionAction: Equatable {
    case submit
    case insertLineBreak
    case deferToSystem

    static func resolve(
        selector: Selector,
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> TerminalAIComposerSubmissionAction {
        guard !hasMarkedText else { return .deferToSystem }

        if selector == #selector(NSResponder.insertLineBreak(_:)) {
            return .insertLineBreak
        }

        if selector == #selector(NSResponder.insertNewline(_:)) {
            return modifiers.contains(.shift) ? .insertLineBreak : .submit
        }

        return .deferToSystem
    }
}

struct TerminalAIComposerInputView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.isEditable = isEnabled
        textView.isSelectable = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.lastSyncedText = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else {
            return
        }

        if context.coordinator.changeOrigin == .textView {
            context.coordinator.changeOrigin = .swiftUI
        } else if context.coordinator.lastSyncedText != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange)
            context.coordinator.lastSyncedText = text
        }

        textView.isEditable = isEnabled
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        enum ChangeOrigin {
            case swiftUI
            case textView
        }

        @Binding var text: String
        let onSubmit: () -> Void
        weak var textView: NSTextView?
        var lastSyncedText: String
        var changeOrigin: ChangeOrigin = .swiftUI

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
            self.lastSyncedText = text.wrappedValue
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            changeOrigin = .textView
            let updated = textView.string
            lastSyncedText = updated
            text = updated
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            let action = TerminalAIComposerSubmissionAction.resolve(
                selector: commandSelector,
                modifiers: modifiers,
                hasMarkedText: textView.hasMarkedText()
            )

            switch action {
            case .submit:
                onSubmit()
                return true
            case .insertLineBreak:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .deferToSystem:
                return false
            }
        }
    }
}
