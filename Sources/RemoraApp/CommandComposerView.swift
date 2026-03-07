import AppKit
import SwiftUI

final class CommandComposerTextView: NSTextView {
    var onSubmit: ((String) -> Void)?
    var onRequestShellCompletion: (() -> Void)?

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = container ?? NSTextContainer(size: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: frameRect.width, height: .greatestFiniteMagnitude)
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        super.init(frame: frameRect, textContainer: textContainer)
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isGrammarCheckingEnabled = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        minSize = NSSize(width: 0, height: 0)
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: 6)
        backgroundColor = .clear
        drawsBackground = false
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        insertionPointColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        selectedTextAttributes = [
            .backgroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.16),
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1.0),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(string)
        case #selector(NSResponder.insertTab(_:)):
            onRequestShellCompletion?()
        case #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            insertText("\n", replacementRange: selectedRange())
        default:
            super.doCommand(by: selector)
        }
    }
}

struct CommandComposerView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var isFocused: Bool = false
    var onSubmit: () -> Void
    var onRequestShellCompletion: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = CommandComposerTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.onSubmit = { _ in onSubmit() }
        textView.onRequestShellCompletion = onRequestShellCompletion
        textView.string = text
        textView.setSelectedRange(selection)
        textView.setAccessibilityIdentifier("terminal-command-composer-editor")

        scrollView.documentView = textView
        scrollView.setAccessibilityIdentifier("terminal-command-composer-scroll")
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? CommandComposerTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = { _ in onSubmit() }
        textView.onRequestShellCompletion = onRequestShellCompletion

        if textView.string != text {
            textView.string = text
        }
        if textView.selectedRange() != selection {
            textView.setSelectedRange(selection)
        }
        if isFocused, textView.window?.firstResponder as AnyObject? !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandComposerView

        init(parent: CommandComposerView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.selection = textView.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selection = textView.selectedRange()
        }
    }
}
