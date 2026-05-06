import AppKit

enum LiveLogUpdate {
    case replace(String)
    case append(String)
}

@MainActor
final class RemoteLiveLogWindowManager: ObservableObject {
    private final class WindowRecord {
        let path: String
        let controller: RemoteLiveLogWindowController

        init(path: String, controller: RemoteLiveLogWindowController) {
            self.path = path
            self.controller = controller
        }
    }

    private var windows: [String: WindowRecord] = [:]
    private let fileTransfer: FileTransferViewModel

    init(fileTransfer: FileTransferViewModel) {
        self.fileTransfer = fileTransfer
    }

    func present(path: String) {
        let normalizedPath = NSString(string: path).standardizingPath

        if let existing = windows[normalizedPath] {
            existing.controller.showWindow(nil)
            existing.controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = RemoteLiveLogViewerViewModel(path: normalizedPath, fileTransfer: fileTransfer)
        let controller = RemoteLiveLogWindowController(viewModel: viewModel) { [weak self] in
            self?.windows.removeValue(forKey: normalizedPath)
        }
        applyAppearanceMode(to: controller.window)
        positionWindowNearPrimaryWindow(controller.window)
        windows[normalizedPath] = WindowRecord(path: normalizedPath, controller: controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppearanceMode(to window: NSWindow?) {
        guard let window else { return }
        let rawValue = AppPreferences.shared.value(for: \.appearanceModeRawValue)
        let mode = AppAppearanceMode.resolved(from: rawValue)
        if let appearanceName = mode.nsAppearanceName {
            window.appearance = NSAppearance(named: appearanceName)
        } else {
            window.appearance = nil
        }
    }

    private func positionWindowNearPrimaryWindow(_ window: NSWindow?) {
        guard let window else { return }

        let anchorWindow: NSWindow? = {
            if let keyWindow = NSApp.keyWindow, keyWindow != window {
                return keyWindow
            }
            if let mainWindow = NSApp.mainWindow, mainWindow != window {
                return mainWindow
            }
            return NSApp.windows.first(where: { $0.isVisible && $0 != window })
        }()

        guard let anchorWindow else { return }

        let anchorFrame = anchorWindow.frame
        var targetFrame = window.frame
        targetFrame.origin.x = anchorFrame.minX + 32
        targetFrame.origin.y = anchorFrame.maxY - targetFrame.height - 32

        let visibleFrame = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        if let visibleFrame {
            if targetFrame.maxX > visibleFrame.maxX {
                targetFrame.origin.x = visibleFrame.maxX - targetFrame.width
            }
            if targetFrame.minX < visibleFrame.minX {
                targetFrame.origin.x = visibleFrame.minX
            }
            if targetFrame.maxY > visibleFrame.maxY {
                targetFrame.origin.y = visibleFrame.maxY - targetFrame.height
            }
            if targetFrame.minY < visibleFrame.minY {
                targetFrame.origin.y = visibleFrame.minY
            }
        }

        window.setFrame(targetFrame, display: true)
    }
}

@MainActor
final class RemoteLiveLogWindowController: NSWindowController, NSWindowDelegate {
    let viewModel: RemoteLiveLogViewerViewModel
    let viewController: AppKitCodeMirrorLogViewerViewController
    private let onClose: () -> Void

    init(viewModel: RemoteLiveLogViewerViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.viewController = AppKitCodeMirrorLogViewerViewController()
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.title = tr("Live View")

        super.init(window: window)
        window.delegate = self
        configureBindings()
        Task { await viewModel.load() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureBindings() {
        viewController.onRefresh = { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.refresh(showLoading: true) }
        }
        viewController.onApplyLineCount = { [weak self] count in
            guard let self else { return }
            Task { await self.viewModel.applyLineCount(count) }
        }
        viewController.onToggleFollow = { [weak self] enabled in
            self?.viewModel.setFollowing(enabled)
        }
        viewController.onDownload = { [weak self] in
            guard let self else { return }
            Task { _ = await self.viewModel.queueDownload() }
        }
        viewController.onCopyPath = { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(self.viewModel.path, forType: .string)
        }
        viewController.onClose = { [weak self] in
            self?.close()
        }

        Task { [weak self] in
            guard let self else { return }
            for await update in self.viewModel.updatesStream {
                self.viewController.apply(update: update, follow: self.viewModel.isFollowing)
                self.viewController.setPath(self.viewModel.path)
                self.viewController.setFollowing(self.viewModel.isFollowing)
                self.viewController.setLineCount(self.viewModel.lineCount)
                self.viewController.setLoading(self.viewModel.isLoading)
                self.viewController.setError(self.viewModel.errorMessage)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stop()
        onClose()
    }
}

@MainActor
final class AppKitCodeMirrorLogViewerViewController: NSViewController {
    private let editorViewController = AppKitCodeMirrorEditorViewController(
        interactionMode: .logViewer,
        descriptor: EditorDocumentDescriptor(
            id: "log-viewer",
            path: nil,
            language: .plain,
            isEditable: false,
            lineWrapping: false
        ),
        initialContent: EditorInitialContent(
            documentID: "log-viewer",
            text: "",
            contentVersion: 0
        )
    )

    var onRefresh: (() -> Void)?
    var onApplyLineCount: ((Int) -> Void)?
    var onToggleFollow: ((Bool) -> Void)?
    var onDownload: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onClose: (() -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let followToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let lineCountField = NSTextField(string: "")
    private let loadingIndicator = NSProgressIndicator()
    private let errorLabel = NSTextField(labelWithString: "")
    private let maxLogChars = 2 * 1024 * 1024

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let titleLabel = NSTextField(labelWithString: tr("Live View"))
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        pathLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor

        let downloadButton = NSButton(title: tr("Download File"), target: self, action: #selector(handleDownload))
        let copyPathButton = NSButton(title: tr("Copy Path"), target: self, action: #selector(handleCopyPath))
        let readOnlyLabel = NSTextField(labelWithString: tr("Read-only"))
        readOnlyLabel.textColor = .secondaryLabelColor

        followToggle.title = tr("Follow")
        followToggle.setButtonType(.switch)
        followToggle.target = self
        followToggle.action = #selector(handleToggleFollow)

        let linesLabel = NSTextField(labelWithString: tr("Lines"))
        linesLabel.textColor = .secondaryLabelColor
        lineCountField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let applyButton = NSButton(title: tr("Apply"), target: self, action: #selector(handleApply))
        let refreshButton = NSButton(title: tr("Refresh"), target: self, action: #selector(handleRefresh))
        let closeButton = NSButton(title: tr("Close"), target: self, action: #selector(handleClose))

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0

        let headerStack = NSStackView(views: [titleLabel, pathLabel, downloadButton, copyPathButton, readOnlyLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8

        let controlsStack = NSStackView(views: [followToggle, linesLabel, lineCountField, applyButton, refreshButton])
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 8

        addChild(editorViewController)
        let editorView = editorViewController.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let spacer = NSView()
        let closeRow = NSStackView(views: [spacer, closeButton])
        closeRow.orientation = .horizontal
        closeRow.alignment = .centerY

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(controlsStack)
        rootStack.addArrangedSubview(editorView)
        rootStack.addArrangedSubview(errorLabel)
        rootStack.addArrangedSubview(closeRow)

        view.addSubview(rootStack)
        view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            editorView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),

            loadingIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            loadingIndicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])

        editorViewController.webView.evaluateJavaScript("window.RemoraEditor.setMaxLogChars && window.RemoraEditor.setMaxLogChars(\(maxLogChars))")
    }

    func apply(update: LiveLogUpdate, follow: Bool) {
        switch update {
        case .replace(let text):
            call("window.RemoraEditor.setLogDocument", arguments: [text, follow])
        case .append(let delta):
            call("window.RemoraEditor.appendLogText", arguments: [delta, follow])
        }
    }

    func setLoading(_ loading: Bool) {
        if loading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }

    func setError(_ message: String?) {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        errorLabel.stringValue = trimmed
        errorLabel.isHidden = trimmed.isEmpty
    }

    func setPath(_ path: String) {
        pathLabel.stringValue = path
    }

    func setLineCount(_ count: Int) {
        lineCountField.stringValue = "\(count)"
    }

    func setFollowing(_ enabled: Bool) {
        followToggle.state = enabled ? .on : .off
    }

    private func call(_ function: String, arguments: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let jsonArray = String(data: data, encoding: .utf8),
              jsonArray.count >= 2
        else {
            return
        }
        let json = String(jsonArray.dropFirst().dropLast())
        editorViewController.webView.evaluateJavaScript("\(function)(\(json))")
    }

    @objc private func handleRefresh() { onRefresh?() }
    @objc private func handleApply() { onApplyLineCount?(Int(lineCountField.stringValue) ?? FileTransferViewModel.defaultRemoteLogTailLineCount) }
    @objc private func handleToggleFollow() { onToggleFollow?(followToggle.state == .on) }
    @objc private func handleDownload() { onDownload?() }
    @objc private func handleCopyPath() { onCopyPath?() }
    @objc private func handleClose() { onClose?() }
}

@MainActor
final class RemoteLiveLogViewerViewModel {
    private static let maxLogChars = 2 * 1024 * 1024

    let path: String
    private let fileTransfer: FileTransferViewModel
    private var lastText = ""
    private var continuation: AsyncStream<LiveLogUpdate>.Continuation?
    private(set) lazy var updatesStream: AsyncStream<LiveLogUpdate> = {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }()

    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isFollowing = true
    private(set) var lineCount = FileTransferViewModel.defaultRemoteLogTailLineCount
    private(set) var errorMessage: String?
    private var followTask: Task<Void, Never>?

    init(path: String, fileTransfer: FileTransferViewModel) {
        self.path = path
        self.fileTransfer = fileTransfer
    }

    func load() async {
        if isFollowing {
            startFollowStream(showLoading: true)
        } else {
            await refresh(showLoading: true)
        }
    }

    func refresh(showLoading: Bool = false) async {
        if isFollowing {
            startFollowStream(showLoading: showLoading)
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true
        if showLoading { isLoading = true }
        defer {
            isRefreshing = false
            if showLoading { isLoading = false }
        }

        do {
            let latest = try await fileTransfer.loadRemoteLogTail(path: path, lineCount: lineCount)
            publish(newText: latest)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setFollowing(_ enabled: Bool) {
        guard isFollowing != enabled else { return }
        isFollowing = enabled
        if enabled {
            startFollowStream(showLoading: lastText.isEmpty)
        } else {
            stop()
        }
    }

    func applyLineCount(_ value: Int) async {
        let clamped = min(max(value, 1), FileTransferViewModel.maxRemoteLogTailLineCount)
        guard clamped != lineCount else { return }
        lineCount = clamped
        lastText = ""
        continuation?.yield(.replace(""))
        if isFollowing {
            startFollowStream(showLoading: false)
        } else {
            await refresh(showLoading: false)
        }
    }

    func stop() {
        followTask?.cancel()
        followTask = nil
        isLoading = false
        isRefreshing = false
    }

    func queueDownload() async -> Bool {
        do {
            try await fileTransfer.enqueueDownload(path: path)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func startFollowStream(showLoading: Bool) {
        stop()
        if showLoading { isLoading = true }
        isRefreshing = true
        errorMessage = nil

        followTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.fileTransfer.streamRemoteLogTail(path: self.path, lineCount: self.lineCount)
                self.lastText = ""
                self.continuation?.yield(.replace(""))
                self.isRefreshing = false

                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    let next = self.lastText + chunk
                    self.publish(newText: next)
                    self.errorMessage = nil
                    if self.isLoading {
                        self.isLoading = false
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isFollowing = false
            }

            self.isLoading = false
            self.isRefreshing = false
            self.followTask = nil
        }
    }

    private func publish(newText: String) {
        let truncated = truncateLog(newText)
        if truncated.hasPrefix(lastText) {
            let delta = String(truncated.dropFirst(lastText.count))
            if !delta.isEmpty {
                continuation?.yield(.append(delta))
            }
        } else {
            continuation?.yield(.replace(truncated))
        }
        lastText = truncated
    }

    private func truncateLog(_ text: String) -> String {
        guard text.count > Self.maxLogChars else { return text }
        let tail = text.suffix(Self.maxLogChars)
        if let newlineIndex = tail.firstIndex(of: "\n") {
            return String(tail[tail.index(after: newlineIndex)...])
        }
        return String(tail)
    }
}
