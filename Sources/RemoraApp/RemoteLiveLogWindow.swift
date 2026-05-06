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
    private static let defaultContentSize = NSSize(width: 1000, height: 720)
    private static let minimumContentSize = NSSize(width: 640, height: 400)

    let viewModel: RemoteLiveLogViewerViewModel
    let viewController: AppKitCodeMirrorLogViewerViewController
    private let onClose: () -> Void

    init(viewModel: RemoteLiveLogViewerViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.viewController = AppKitCodeMirrorLogViewerViewController()
        self.onClose = onClose

        let contentView = NSView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.contentMinSize = Self.minimumContentSize
        window.minSize = NSSize(
            width: Self.minimumContentSize.width,
            height: Self.minimumContentSize.height + 32
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.title = tr("Live View")

        super.init(window: window)
        let childView = viewController.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            childView.topAnchor.constraint(equalTo: contentView.topAnchor),
            childView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentSize.width),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentSize.height),
        ])
        window.setContentSize(Self.defaultContentSize)
        window.delegate = self
        logWindowGeometry(context: "init")
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

    func windowDidResize(_ notification: Notification) {
        logWindowGeometry(context: "windowDidResize")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        logWindowGeometry(context: "windowDidBecomeKey")
    }

    private func logWindowGeometry(context: String) {
        guard let window else { return }
        let frame = window.frame
        let contentRect = window.contentRect(forFrameRect: frame)
        let layoutRect = window.contentLayoutRect
        let contentBounds = window.contentView?.bounds ?? .zero
        EditorDebugLog.log(
            "liveLog.window[\(context)] frame=\(frame.debugDescription) contentRect=\(contentRect.debugDescription) contentLayoutRect=\(layoutRect.debugDescription) contentBounds=\(contentBounds.debugDescription) styleMask=\(window.styleMask.rawValue)"
        )
    }
}

@MainActor
final class AppKitCodeMirrorLogViewerViewController: NSViewController {
    private static let preferredViewerSize = NSSize(width: 1000, height: 720)
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
    private let headerStack = NSStackView()
    private let controlsStack = NSStackView()
    private let closeRow = NSStackView()

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.preferredViewerSize))
        preferredContentSize = Self.preferredViewerSize
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
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerStack.setViews([titleLabel, pathLabel, downloadButton, copyPathButton, readOnlyLabel], in: .leading)
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        controlsStack.setViews([followToggle, linesLabel, lineCountField, applyButton, refreshButton], in: .leading)
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 8
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        addChild(editorViewController)
        let editorView = editorViewController.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorView.setContentCompressionResistancePriority(.required, for: .vertical)

        let spacer = NSView()
        closeRow.setViews([spacer, closeButton], in: .leading)
        closeRow.orientation = .horizontal
        closeRow.alignment = .centerY
        closeRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(controlsStack)
        view.addSubview(editorView)
        view.addSubview(errorLabel)
        view.addSubview(closeRow)
        view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),

            controlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controlsStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),

            closeRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            closeRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            closeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            errorLabel.bottomAnchor.constraint(equalTo: closeRow.topAnchor, constant: -8),

            editorView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            editorView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            editorView.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 10),
            editorView.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -8),
            editorView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),

            loadingIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            loadingIndicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])

        editorViewController.webView.evaluateJavaScript("window.RemoraEditor.setMaxLogChars && window.RemoraEditor.setMaxLogChars(\(maxLogChars))")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let editorView = editorViewController.view
        EditorDebugLog.log(
            "liveLog.viewDidLayout view=\(view.frame.debugDescription) header=\(headerStack.frame.debugDescription) controls=\(controlsStack.frame.debugDescription) editor=\(editorView.frame.debugDescription) error=\(errorLabel.frame.debugDescription) closeRow=\(closeRow.frame.debugDescription)"
        )
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
