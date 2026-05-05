import AppKit
import WebKit

@MainActor
final class AppKitCodeMirrorEditorViewController: NSViewController {
    var descriptor: EditorDocumentDescriptor {
        didSet {
            coordinator.parentDescriptor = descriptor
            applyStateIfReady()
        }
    }

    var initialContent: EditorInitialContent {
        didSet {
            coordinator.parentInitialContent = initialContent
            applyStateIfReady()
        }
    }

    var saveRequestID: Int = 0 {
        didSet {
            coordinator.parentSaveRequestID = saveRequestID
            applyStateIfReady()
        }
    }

    var savedRevision: Int? {
        didSet {
            coordinator.parentSavedRevision = savedRevision
            applyStateIfReady()
        }
    }

    var autoScrollToBottom = false {
        didSet {
            coordinator.parentAutoScrollToBottom = autoScrollToBottom
        }
    }

    var onReady: (() -> Void)?
    var onChange: ((Int) -> Void)?
    var onEvent: ((EditorEvent) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onSaveRequested: ((EditorSaveRequest) -> Void)?
    var onError: ((String) -> Void)?

    private lazy var coordinator = AppKitCodeMirrorCoordinator(
        descriptor: descriptor,
        initialContent: initialContent,
        saveRequestID: saveRequestID,
        savedRevision: savedRevision,
        autoScrollToBottom: autoScrollToBottom
    )

    private(set) lazy var webView: FocusableCodeMirrorWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let userContentController = WKUserContentController()
        userContentController.add(coordinator, name: "remoraEditor")
        configuration.userContentController = userContentController

        let webView = FocusableCodeMirrorWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        coordinator.webView = webView
        return webView
    }()

    init(
        descriptor: EditorDocumentDescriptor,
        initialContent: EditorInitialContent,
        saveRequestID: Int = 0,
        savedRevision: Int? = nil,
        autoScrollToBottom: Bool = false
    ) {
        self.descriptor = descriptor
        self.initialContent = initialContent
        self.saveRequestID = saveRequestID
        self.savedRevision = savedRevision
        self.autoScrollToBottom = autoScrollToBottom
        super.init(nibName: nil, bundle: nil)
        bindCoordinatorCallbacks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        do {
            let html = try Self.inlineEditorHTML()
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            onError?("Failed to load editor resources: \(error.localizedDescription)")
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "remoraEditor")
        webView.navigationDelegate = nil
    }

    private func bindCoordinatorCallbacks() {
        coordinator.onReady = { [weak self] in self?.onReady?() }
        coordinator.onChange = { [weak self] revision in self?.onChange?(revision) }
        coordinator.onEvent = { [weak self] event in self?.onEvent?(event) }
        coordinator.onTextChange = { [weak self] text in self?.onTextChange?(text) }
        coordinator.onSaveRequested = { [weak self] request in self?.onSaveRequested?(request) }
        coordinator.onError = { [weak self] message in self?.onError?(message) }
    }

    func applyStateIfReady() {
        coordinator.updateIfNeeded()
    }

    private static func inlineEditorHTML() throws -> String {
        let bundle = Bundle.module

        func loadResource(named name: String, extension ext: String) throws -> String {
            let directURL = bundle.url(forResource: name, withExtension: ext, subdirectory: "WebEditor")
                ?? bundle.url(forResource: name, withExtension: ext)
            guard let url = directURL else {
                throw NSError(domain: "AppKitCodeMirrorEditorViewController", code: 1, userInfo: [
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
}
