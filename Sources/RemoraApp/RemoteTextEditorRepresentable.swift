import AppKit
import SwiftUI

struct RemoteTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
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
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.isEditable = isEditable
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

        textView.isEditable = isEditable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        enum ChangeOrigin {
            case swiftUI
            case textView
        }

        @Binding var text: String
        weak var textView: NSTextView?
        var lastSyncedText: String
        var changeOrigin: ChangeOrigin = .swiftUI

        init(text: Binding<String>) {
            _text = text
            self.lastSyncedText = text.wrappedValue
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            changeOrigin = .textView
            let updated = textView.string
            lastSyncedText = updated
            text = updated
        }
    }
}
