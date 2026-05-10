import AppKit
import SwiftUI
import WebKit

struct RemoraEditorWebView: NSViewRepresentable {
    var descriptor: EditorDocumentDescriptor
    var initialContent: EditorInitialContent
    var saveRequestID: Int = 0
    var savedRevision: Int? = nil
    var textInsertion: EditorTextInsertion? = nil
    var autoScrollToBottom: Bool = false
    var onReady: (() -> Void)? = nil
    var onChange: ((Int) -> Void)? = nil
    var onEvent: ((EditorEvent) -> Void)? = nil
    var onTextChange: ((String) -> Void)? = nil
    var onSaveRequested: ((EditorSaveRequest) -> Void)? = nil
    var onError: ((String) -> Void)? = nil

    func makeCoordinator() -> RemoraEditorCoordinator {
        RemoraEditorCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "remoraEditor")
        configuration.userContentController = userContentController

        let webView = FocusableCodeMirrorWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        do {
            let html = try Self.inlineEditorHTML()
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            assertionFailure("Failed to build inline editor HTML: \(error.localizedDescription)")
            onError?("Failed to load editor resources: \(error.localizedDescription)")
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        EditorDebugLog.log(
            "updateNSView ready=\(context.coordinator.debugIsReady) documentID=\(descriptor.id) contentVersion=\(initialContent.contentVersion) saveRequestID=\(saveRequestID)"
        )
        context.coordinator.updateIfNeeded()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: RemoraEditorCoordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "remoraEditor")
        nsView.navigationDelegate = nil
    }

    private static func inlineEditorHTML() throws -> String {
        let bundle = editorResourceBundle()

        func loadResource(named name: String, extension ext: String) throws -> String {
            let directURL = bundle.url(forResource: name, withExtension: ext, subdirectory: "WebEditor")
                ?? bundle.url(forResource: name, withExtension: ext)
            guard let url = directURL else {
                throw NSError(domain: "RemoraEditorWebView", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Missing \(name).\(ext) in bundle resources"
                ])
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        let css = try loadResource(named: "editor", extension: "css")
        let js = try loadResource(named: "editor", extension: "js")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
          <title>Remora Editor</title>
          <style>\(css)</style>
        </head>
        <body>
          <div id="editor"></div>
          <script>\(js)</script>
        </body>
        </html>
        """
    }

    private static func editorResourceBundle() -> Bundle {
#if SWIFT_PACKAGE
        return Bundle.module
#else
        return Bundle.main
#endif
    }
}
