import AppKit
import WebKit

final class FocusableCodeMirrorWebView: WKWebView {
    var interactionMode: RemoraEditorInteractionMode = .editor

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        invokeEditorAction("focusPreservingScroll")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch interactionMode {
        case .editor:
            switch key {
            case "a":
                selectAll(nil)
                return true
            case "c":
                copy(nil)
                return true
            case "x":
                cut(nil)
                return true
            case "v":
                paste(nil)
                return true
            case "s":
                invokeEditorAction("requestSave")
                return true
            case "f":
                invokeEditorAction("openSearch")
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        case .logViewer:
            switch key {
            case "c":
                copy(nil)
                return true
            case "v", "x", "s":
                NSSound.beep()
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
    }

    override func selectAll(_ sender: Any?) {
        invokeEditorAction("selectAll")
    }

    @objc func copy(_ sender: Any?) {
        evaluateJavaScript("window.RemoraEditor.getSelectionText && window.RemoraEditor.getSelectionText()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    @objc func cut(_ sender: Any?) {
        evaluateJavaScript("window.RemoraEditor.getSelectionText && window.RemoraEditor.getSelectionText()") { [weak self] result, _ in
            guard let self else { return }
            guard let text = result as? String, !text.isEmpty else { return }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.invokeEditorAction("cutSelection")
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }

        invokeEditorFunction("pasteText", stringArgument: text)
    }

    private func invokeEditorAction(_ name: String) {
        evaluateJavaScript("window.RemoraEditor.\(name) && window.RemoraEditor.\(name)()")
    }

    private func invokeEditorFunction(_ name: String, stringArgument: String) {
        guard let data = try? JSONEncoder().encode([stringArgument]),
              let jsonArray = String(data: data, encoding: .utf8),
              jsonArray.count >= 2
        else {
            return
        }

        let json = String(jsonArray.dropFirst().dropLast())
        evaluateJavaScript("window.RemoraEditor.\(name) && window.RemoraEditor.\(name)(\(json))")
    }
}
