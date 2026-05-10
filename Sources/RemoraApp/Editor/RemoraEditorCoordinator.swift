import Foundation
import WebKit

final class RemoraEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private enum TextRequestReason {
        case change
        case save(revision: Int)
    }

    var parent: RemoraEditorWebView
    weak var webView: WKWebView?

    private var isReady = false
    private var lastAppliedDescriptor: EditorDocumentDescriptor?
    private var lastAppliedDocumentID: String?
    private var lastAppliedContentVersion: Int?
    private var lastAppliedTheme: EditorTheme?
    private var lastProcessedSaveRequestID = 0
    private var lastProcessedTextInsertionID = 0
    private var lastMarkedSavedRevision: Int?
    private var isFetchingText = false
    private var pendingChangeFetch = false
    private var pendingSaveRevision: Int?

    init(parent: RemoraEditorWebView) {
        self.parent = parent
    }

    var debugIsReady: Bool {
        isReady
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "remoraEditor" else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: message.body)
            let decoded = try JSONDecoder().decode(EditorBridgeMessage.self, from: data)
            EditorDebugLog.log(
                "bridge <- \(decoded.type.rawValue) rev=\(decoded.revision.map(String.init) ?? "-") msg=\(decoded.message ?? "-")"
            )
            handle(decoded)
        } catch {
            parent.onError?("Failed to decode editor bridge message: \(error.localizedDescription)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        EditorDebugLog.log("didFinish navigation")
        updateIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        parent.onError?("Editor navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        parent.onError?("Editor provisional navigation failed: \(error.localizedDescription)")
    }

    func updateIfNeeded() {
        guard isReady else { return }

        let needsDocumentReload =
            lastAppliedDocumentID != parent.descriptor.id ||
            lastAppliedContentVersion != parent.initialContent.contentVersion

        if needsDocumentReload {
            setDocument(parent.initialContent, descriptor: parent.descriptor)
        } else {
            applyDescriptorIfNeeded(parent.descriptor)
        }

        applyThemeIfNeeded()
        processTextInsertionIfNeeded(parent.textInsertion)
        processSaveRequestIfNeeded(parent.saveRequestID)
        applySavedRevisionIfNeeded(parent.savedRevision)
    }

    private func handle(_ message: EditorBridgeMessage) {
        switch message.type {
        case .ready:
            isReady = true
            updateIfNeeded()
            parent.onReady?()
            parent.onEvent?(.ready)

        case .changed:
            let revision = message.revision ?? 0
            parent.onChange?(revision)
            parent.onEvent?(.changed(revision: revision))
            // Full-text pull-on-change is retained only for MirroredRemoraEditorView.
            // The remote file editor path must not mirror live text back into Swift.
            if parent.onTextChange != nil {
                requestText(reason: .change)
            }

        case .saveRequested:
            let revision = message.revision ?? 0
            requestText(reason: .save(revision: revision))

        case .debug:
            if let message = message.message {
                EditorDebugLog.log("js.debug \(message)")
            }

        case .error:
            let message = message.message ?? "Unknown editor error"
            parent.onError?(message)
            parent.onEvent?(.error(message))
        }
    }

    private func applyDescriptorIfNeeded(_ descriptor: EditorDocumentDescriptor) {
        let previous = lastAppliedDescriptor

        if previous?.language != descriptor.language {
            EditorDebugLog.log("setLanguage \(descriptor.language.rawValue)")
            call("window.RemoraEditor.setLanguage", argument: descriptor.language.rawValue)
        }

        if previous?.isEditable != descriptor.isEditable {
            EditorDebugLog.log("setEditable \(descriptor.isEditable)")
            call("window.RemoraEditor.setEditable", argument: descriptor.isEditable)
        }

        if previous?.lineWrapping != descriptor.lineWrapping {
            EditorDebugLog.log("setLineWrapping \(descriptor.lineWrapping)")
            call("window.RemoraEditor.setLineWrapping", argument: descriptor.lineWrapping)
        }

        lastAppliedDescriptor = descriptor
    }

    private func setDocument(_ initialContent: EditorInitialContent, descriptor: EditorDocumentDescriptor) {
        let payload = EditorDocumentPayload(
            documentID: descriptor.id,
            contentVersion: initialContent.contentVersion,
            text: initialContent.text,
            path: descriptor.path,
            language: descriptor.language,
            isEditable: descriptor.isEditable,
            lineWrapping: descriptor.lineWrapping
        )

        EditorDebugLog.log(
            "setDocument id=\(descriptor.id) contentVersion=\(initialContent.contentVersion) chars=\(initialContent.text.count)"
        )
        call("window.RemoraEditor.setDocument", argument: payload) { [weak self] in
            guard let self else { return }
            self.lastAppliedDescriptor = descriptor
            self.lastAppliedDocumentID = descriptor.id
            self.lastAppliedContentVersion = initialContent.contentVersion
            self.lastMarkedSavedRevision = nil
            if self.parent.autoScrollToBottom {
                self.call("window.RemoraEditor.scrollToBottom")
            }
        }
    }

    private func applyThemeIfNeeded() {
        guard let webView else { return }

        let theme: EditorTheme = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark
            : .light

        guard theme != lastAppliedTheme else { return }
        lastAppliedTheme = theme
        EditorDebugLog.log("setTheme \(theme.rawValue)")
        call("window.RemoraEditor.setTheme", argument: theme.rawValue)
    }

    private func processSaveRequestIfNeeded(_ saveRequestID: Int) {
        guard saveRequestID != lastProcessedSaveRequestID else { return }
        lastProcessedSaveRequestID = saveRequestID
        EditorDebugLog.log("requestSave saveRequestID=\(saveRequestID)")
        call("window.RemoraEditor.requestSave")
    }

    private func processTextInsertionIfNeeded(_ insertion: EditorTextInsertion?) {
        guard let insertion else { return }
        guard insertion.id != lastProcessedTextInsertionID else { return }
        lastProcessedTextInsertionID = insertion.id
        EditorDebugLog.log("insertText insertionID=\(insertion.id) chars=\(insertion.text.count)")
        call("window.RemoraEditor.insertText", argument: insertion.text)
    }

    private func applySavedRevisionIfNeeded(_ savedRevision: Int?) {
        guard let savedRevision else { return }
        guard savedRevision != lastMarkedSavedRevision else { return }
        lastMarkedSavedRevision = savedRevision
        EditorDebugLog.log("markSaved revision=\(savedRevision)")
        call("window.RemoraEditor.markSaved", argument: savedRevision)
    }

    private func requestText(reason: TextRequestReason) {
        guard let webView else { return }
        guard !isFetchingText else {
            switch reason {
            case .change:
                pendingChangeFetch = true
            case .save(let revision):
                pendingSaveRevision = revision
            }
            return
        }

        isFetchingText = true
        webView.evaluateJavaScript("window.RemoraEditor.getText()") { [weak self] result, error in
            guard let self else { return }
            self.isFetchingText = false

            if let error {
                self.parent.onError?("Editor getText failed: \(error.localizedDescription)")
                self.flushPendingTextRequests()
                return
            }

            let text = result as? String ?? ""

            switch reason {
            case .change:
                EditorDebugLog.log("getText change chars=\(text.count)")
                self.parent.onTextChange?(text)
            case .save(let revision):
                EditorDebugLog.log("getText save rev=\(revision) chars=\(text.count)")
                self.parent.onSaveRequested?(EditorSaveRequest(revision: revision, text: text))
            }

            self.flushPendingTextRequests()
        }
    }

    private func flushPendingTextRequests() {
        if let pendingSaveRevision {
            self.pendingSaveRevision = nil
            requestText(reason: .save(revision: pendingSaveRevision))
            return
        }

        if pendingChangeFetch {
            pendingChangeFetch = false
            requestText(reason: .change)
        }
    }

    private func call(_ function: String, completion: (() -> Void)? = nil) {
        EditorDebugLog.log("js -> \(function)()")
        webView?.evaluateJavaScript("\(function)()") { _, error in
            if let error {
                self.parent.onError?("Editor JS call failed: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    private func call<T: Encodable>(_ function: String, argument: T, completion: (() -> Void)? = nil) {
        guard let json = encodeJavaScriptArgument(argument) else {
            parent.onError?("Failed to encode editor command arguments")
            completion?()
            return
        }

        EditorDebugLog.log("js -> \(function)(arg)")
        webView?.evaluateJavaScript("\(function)(\(json))") { _, error in
            if let error {
                self.parent.onError?("Editor JS call failed: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    private func encodeJavaScriptArgument<T: Encodable>(_ argument: T) -> String? {
        let encoder = JSONEncoder()

        guard let data = try? encoder.encode([argument]),
              let jsonArray = String(data: data, encoding: .utf8),
              jsonArray.count >= 2
        else {
            return nil
        }

        return String(jsonArray.dropFirst().dropLast())
    }
}
