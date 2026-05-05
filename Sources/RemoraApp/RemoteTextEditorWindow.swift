import AppKit

@MainActor
final class RemoteTextEditorWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    private final class WindowRecord {
        let path: String
        let viewModel: RemoteTextEditorViewModel
        let windowController: RemoteTextEditorWindowController

        init(path: String, viewModel: RemoteTextEditorViewModel, windowController: RemoteTextEditorWindowController) {
            self.path = path
            self.viewModel = viewModel
            self.windowController = windowController
        }
    }

    private var windows: [String: WindowRecord] = [:]
    private let fileTransfer: FileTransferViewModel

    init(fileTransfer: FileTransferViewModel) {
        self.fileTransfer = fileTransfer
    }

    func present(path: String, loadOptions: RemoteTextDocumentLoadOptions = RemoteTextDocumentLoadOptions()) {
        let normalizedPath = NSString(string: path).standardizingPath

        if let existing = windows[normalizedPath] {
            existing.windowController.showWindow(nil)
            existing.windowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = RemoteTextEditorViewModel(
            path: normalizedPath,
            loadOptions: loadOptions,
            fileTransfer: fileTransfer
        )

        let windowController = RemoteTextEditorWindowController(viewModel: viewModel)
        windowController.window?.identifier = NSUserInterfaceItemIdentifier("remora.remote-editor.\(normalizedPath)")
        windowController.window?.delegate = self
        applyAppearanceMode(to: windowController.window)

        let record = WindowRecord(path: normalizedPath, viewModel: viewModel, windowController: windowController)
        windows[normalizedPath] = record
        refreshWindowTitle(for: normalizedPath)
        positionWindowNearPrimaryWindow(windowController.window)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshWindowTitle(for path: String) {
        guard let record = windows[path], let window = record.windowController.window else { return }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let prefix: String = {
            switch record.viewModel.saveStatus {
            case .idle:
                return record.viewModel.isDirty ? "Not Saved - " : ""
            case .saving:
                return "Saving… - "
            case .failed:
                return "Save Failed - "
            }
        }()
        window.title = prefix + fileName
        window.isDocumentEdited = record.viewModel.isDirty
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let record = windows.values.first(where: { $0.windowController.window === sender }) else { return true }
        guard record.viewModel.isDirty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Unsaved changes")
        alert.informativeText = tr("This file has unsaved changes. Close without saving?")
        alert.addButton(withTitle: tr("Close Without Saving"))
        alert.addButton(withTitle: tr("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value.windowController.window !== window }
    }
}

@MainActor
final class RemoteTextEditorWindowController: NSWindowController {
    let viewModel: RemoteTextEditorViewModel
    let editorViewController: AppKitCodeMirrorEditorViewController

    private lazy var loadingIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.controlSize = .small
        indicator.style = .spinning
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private lazy var errorLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.backgroundColor = NSColor.systemRed.withAlphaComponent(0.88)
        label.drawsBackground = true
        label.isBordered = false
        label.isHidden = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(viewModel: RemoteTextEditorViewModel) {
        self.viewModel = viewModel
        self.editorViewController = AppKitCodeMirrorEditorViewController(
            descriptor: viewModel.documentDescriptor,
            initialContent: viewModel.initialContent
        )

        let window = NSWindow(contentViewController: editorViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred

        super.init(window: window)
        configureBindings()
        installOverlayUI()
        Task { await loadDocument() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureBindings() {
        editorViewController.onChange = { [weak self] revision in
            self?.viewModel.markDirty(revision: revision)
            self?.refreshWindowState()
        }

        editorViewController.onSaveRequested = { [weak self] request in
            guard let self else { return }
            guard self.viewModel.editorMode.isEditable else { return }
            Task {
                self.loadingIndicator.startAnimation(nil)
                self.window?.title = "Saving… - " + URL(fileURLWithPath: self.viewModel.path).lastPathComponent
                await self.viewModel.save(request: request)
                self.editorViewController.savedRevision = self.viewModel.lastSavedRevision
                self.refreshWindowState()
            }
        }

        editorViewController.onError = { [weak self] message in
            self?.viewModel.errorMessage = message
            self?.refreshWindowState()
        }
    }

    private func installOverlayUI() {
        guard let contentView = window?.contentView else { return }

        loadingIndicator.isDisplayedWhenStopped = false
        contentView.addSubview(loadingIndicator)
        contentView.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            loadingIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            loadingIndicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            errorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
        ])
    }

    private func loadDocument() async {
        loadingIndicator.startAnimation(nil)
        refreshTitle()

        await viewModel.load()
        editorViewController.descriptor = viewModel.documentDescriptor
        editorViewController.initialContent = viewModel.initialContent
        refreshWindowState()
    }

    private func refreshTitle() {
        let fileName = URL(fileURLWithPath: viewModel.path).lastPathComponent

        let prefix: String = {
            if viewModel.isLoading {
                return "Loading… - "
            }
            switch viewModel.saveStatus {
            case .idle:
                return viewModel.isDirty ? "Not Saved - " : ""
            case .saving:
                return "Saving… - "
            case .failed:
                return "Save Failed - "
            }
        }()

        window?.title = prefix + fileName
        window?.isDocumentEdited = viewModel.isDirty
    }

    private func refreshWindowState() {
        editorViewController.descriptor = viewModel.documentDescriptor
        editorViewController.saveRequestID = viewModel.saveRequestID
        editorViewController.savedRevision = viewModel.lastSavedRevision

        if viewModel.isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }

        if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
            errorLabel.stringValue = errorMessage
            errorLabel.isHidden = false
        } else if let modeMessage = viewModel.editorModeMessage {
            errorLabel.stringValue = modeMessage
            errorLabel.isHidden = false
        } else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }

        refreshTitle()
    }
}
