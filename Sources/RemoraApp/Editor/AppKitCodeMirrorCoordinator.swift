import Foundation
import WebKit

final class AppKitCodeMirrorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private enum TextRequestReason {
        case change
        case save(revision: Int)
    }

    var parentDescriptor: EditorDocumentDescriptor
    var parentInitialContent: EditorInitialContent
    var parentSaveRequestID: Int
    var parentSavedRevision: Int?
    var parentTextInsertion: EditorTextInsertion?
    var parentAutoScrollToBottom: Bool

    var onReady: (() -> Void)?
    var onChange: ((Int) -> Void)?
    var onEvent: ((EditorEvent) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onSaveRequested: ((EditorSaveRequest) -> Void)?
    var onError: ((String) -> Void)?

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

    init(
        descriptor: EditorDocumentDescriptor,
        initialContent: EditorInitialContent,
        saveRequestID: Int,
        savedRevision: Int?,
        textInsertion: EditorTextInsertion?,
        autoScrollToBottom: Bool
    ) {
        self.parentDescriptor = descriptor
        self.parentInitialContent = initialContent
        self.parentSaveRequestID = saveRequestID
        self.parentSavedRevision = savedRevision
        self.parentTextInsertion = textInsertion
        self.parentAutoScrollToBottom = autoScrollToBottom
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
            onError?("Failed to decode editor bridge message: \(error.localizedDescription)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        EditorDebugLog.log("didFinish navigation")
        updateIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError?("Editor navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        onError?("Editor provisional navigation failed: \(error.localizedDescription)")
    }

    func updateIfNeeded() {
        guard isReady else { return }

        let needsDocumentReload =
            lastAppliedDocumentID != parentDescriptor.id ||
            lastAppliedContentVersion != parentInitialContent.contentVersion

        if needsDocumentReload {
            setDocument(parentInitialContent, descriptor: parentDescriptor)
        } else {
            applyDescriptorIfNeeded(parentDescriptor)
        }

        applyThemeIfNeeded()
        processTextInsertionIfNeeded(parentTextInsertion)
        processSaveRequestIfNeeded(parentSaveRequestID)
        applySavedRevisionIfNeeded(parentSavedRevision)
    }

    private func handle(_ message: EditorBridgeMessage) {
        switch message.type {
        case .ready:
            isReady = true
            updateIfNeeded()
            call("window.RemoraEditor.focusPreservingScroll")
            call("window.RemoraEditor.debugFocus")
            onReady?()
            onEvent?(.ready)

        case .changed:
            let revision = message.revision ?? 0
            onChange?(revision)
            onEvent?(.changed(revision: revision))
            if onTextChange != nil {
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
            onError?(message)
            onEvent?(.error(message))
        }
    }

    private func applyDescriptorIfNeeded(_ descriptor: EditorDocumentDescriptor) {
        let previous = lastAppliedDescriptor

        if previous?.language != descriptor.language {
            call("window.RemoraEditor.setLanguage", argument: descriptor.language.rawValue)
        }

        if previous?.isEditable != descriptor.isEditable {
            call("window.RemoraEditor.setEditable", argument: descriptor.isEditable)
        }

        if previous?.lineWrapping != descriptor.lineWrapping {
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

        lastAppliedDescriptor = descriptor
        lastAppliedDocumentID = descriptor.id
        lastAppliedContentVersion = initialContent.contentVersion
        lastMarkedSavedRevision = nil

        call("window.RemoraEditor.setDocument", argument: payload) { [weak self] in
            guard let self else { return }
            if self.parentAutoScrollToBottom {
                self.call("window.RemoraEditor.scrollToBottom")
            }
            self.call("window.RemoraEditor.focusPreservingScroll")
            self.call("window.RemoraEditor.debugFocus")
        }
    }

    private func applyThemeIfNeeded() {
        guard let webView else { return }

        let theme: EditorTheme = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark
            : .light

        guard theme != lastAppliedTheme else { return }
        lastAppliedTheme = theme
        call("window.RemoraEditor.setTheme", argument: theme.rawValue)
    }

    private func processSaveRequestIfNeeded(_ saveRequestID: Int) {
        guard saveRequestID != lastProcessedSaveRequestID else { return }
        lastProcessedSaveRequestID = saveRequestID
        call("window.RemoraEditor.requestSave")
    }

    private func processTextInsertionIfNeeded(_ insertion: EditorTextInsertion?) {
        guard let insertion else { return }
        guard insertion.id != lastProcessedTextInsertionID else { return }
        lastProcessedTextInsertionID = insertion.id
        call("window.RemoraEditor.insertText", argument: insertion.text)
    }

    private func applySavedRevisionIfNeeded(_ savedRevision: Int?) {
        guard let savedRevision else { return }
        guard savedRevision != lastMarkedSavedRevision else { return }
        lastMarkedSavedRevision = savedRevision
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
                self.onError?("Editor getText failed: \(error.localizedDescription)")
                self.flushPendingTextRequests()
                return
            }

            let text = result as? String ?? ""

            switch reason {
            case .change:
                self.onTextChange?(text)
            case .save(let revision):
                self.onSaveRequested?(EditorSaveRequest(revision: revision, text: text))
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
        webView?.evaluateJavaScript("\(function)()") { _, error in
            if let error {
                self.onError?("Editor JS call failed: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    private func call<T: Encodable>(_ function: String, argument: T, completion: (() -> Void)? = nil) {
        guard let json = encodeJavaScriptArgument(argument) else {
            onError?("Failed to encode editor command arguments")
            completion?()
            return
        }

        webView?.evaluateJavaScript("\(function)(\(json))") { _, error in
            if let error {
                self.onError?("Editor JS call failed: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    private func encodeJavaScriptArgument<T: Encodable>(_ argument: T) -> String? {
        guard let data = try? JSONEncoder().encode([argument]),
              let jsonArray = String(data: data, encoding: .utf8),
              jsonArray.count >= 2
        else {
            return nil
        }

        return String(jsonArray.dropFirst().dropLast())
    }
}
