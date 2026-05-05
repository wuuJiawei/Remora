import AppKit
import WebKit

final class FocusableWKWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "s":
            invokeEditorAction("requestSave")
            return true
        case "f":
            invokeEditorAction("openSearch")
            return true
        case "a":
            invokeEditorAction("selectAll")
            return true
        case "z":
            if event.modifierFlags.contains(.shift) {
                invokeEditorAction("redo")
            } else {
                invokeEditorAction("undo")
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func invokeEditorAction(_ name: String) {
        evaluateJavaScript("window.RemoraEditor.\(name) && window.RemoraEditor.\(name)()")
    }
}
