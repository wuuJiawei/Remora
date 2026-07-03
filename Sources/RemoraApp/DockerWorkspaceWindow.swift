import AppKit
import Combine
import SwiftUI
import RemoraCore

@MainActor
final class DockerWorkspaceWindowManager: ObservableObject {
    private final class WindowRecord {
        let id: UUID
        let host: RemoraCore.Host
        let runtimeID: ObjectIdentifier
        let viewModel: DockerPanelViewModel
        let controller: DockerWorkspaceWindowController
        let runtimeObserver: AnyCancellable

        init(
            id: UUID,
            host: RemoraCore.Host,
            runtimeID: ObjectIdentifier,
            viewModel: DockerPanelViewModel,
            controller: DockerWorkspaceWindowController,
            runtimeObserver: AnyCancellable
        ) {
            self.id = id
            self.host = host
            self.runtimeID = runtimeID
            self.viewModel = viewModel
            self.controller = controller
            self.runtimeObserver = runtimeObserver
        }
    }

    private var windows: [UUID: WindowRecord] = [:]

    func present(
        host: RemoraCore.Host,
        runtime: TerminalRuntime,
        onOpenContainerShell: @escaping (RemoraCore.Host, DockerContainer) -> Void
    ) {
        let windowID = UUID()
        let cascadeIndex = windows.count
        let runtimeID = ObjectIdentifier(runtime)
        let viewModel = DockerPanelViewModel()
        viewModel.updateRuntimeBinding(makeBinding(from: runtime, fallbackHost: host))

        let controller = DockerWorkspaceWindowController(
            host: host,
            viewModel: viewModel,
            onOpenContainerShell: { container in
                onOpenContainerShell(host, container)
            },
            onClose: { [weak self] in
                self?.windows.removeValue(forKey: windowID)
            }
        )
        applyAppearanceMode(to: controller.window)
        positionWindowNearPrimaryWindow(controller.window, cascadeIndex: cascadeIndex)
        let runtimeObserver = Publishers.CombineLatest3(
            runtime.$connectionMode,
            runtime.$connectionState,
            runtime.$connectedSSHHost
        )
        .receive(on: RunLoop.main)
        .sink { [weak self, weak viewModel] _, _, _ in
            guard let self, let viewModel else { return }
            viewModel.updateRuntimeBinding(self.makeBinding(from: runtime, fallbackHost: host))
        }
        windows[windowID] = WindowRecord(
            id: windowID,
            host: host,
            runtimeID: runtimeID,
            viewModel: viewModel,
            controller: controller,
            runtimeObserver: runtimeObserver
        )

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

    private func positionWindowNearPrimaryWindow(_ window: NSWindow?, cascadeIndex: Int) {
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
        let clampedIndex = min(max(cascadeIndex, 0), 6)
        let cascadeOffset = CGFloat(clampedIndex) * 28
        var targetFrame = window.frame
        targetFrame.origin.x = anchorFrame.minX + 32 + cascadeOffset
        targetFrame.origin.y = anchorFrame.maxY - targetFrame.height - 32 - cascadeOffset

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

    private func makeBinding(
        from runtime: TerminalRuntime,
        fallbackHost: RemoraCore.Host
    ) -> DockerRuntimeBinding {
        let connectedHost = runtime.connectedSSHHost
        let effectiveHost = connectedHost ?? runtime.reconnectableSSHHost ?? fallbackHost
        return DockerRuntimeBinding(
            runtimeID: ObjectIdentifier(runtime),
            connectionMode: runtime.connectionMode,
            connectionState: runtime.connectionState,
            host: effectiveHost,
            executionMode: .requireExistingSSHConnection
        )
    }
}

@MainActor
final class DockerWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private let host: RemoraCore.Host
    private let viewModel: DockerPanelViewModel
    private let onClose: () -> Void
    private let toolbarController: DockerWindowToolbar
    private let splitController: DockerWindowSplitController
    private let toastController = DockerWindowToastController()
    private var cancellables: Set<AnyCancellable> = []
    private var presentedLogSessionID: UUID?
    private var isPresentingConfirmation = false

    init(
        host: RemoraCore.Host,
        viewModel: DockerPanelViewModel,
        onOpenContainerShell: @escaping (DockerContainer) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.host = host
        self.viewModel = viewModel
        self.onClose = onClose
        self.toolbarController = DockerWindowToolbar()
        self.splitController = DockerWindowSplitController(
            viewModel: viewModel,
            onOpenContainerShell: onOpenContainerShell
        )

        let window = NSWindow(contentViewController: splitController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.title = Self.windowTitle(for: host)
        window.toolbar = toolbarController.toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        super.init(window: window)
        window.delegate = self
        toastController.installIfNeeded(in: window)
        toolbarController.onRefresh = { [weak viewModel] in
            viewModel?.refresh()
        }
        toolbarController.onSearchChanged = { [weak splitController] query in
            splitController?.applyToolbarSearch(query)
        }
        bindWindowPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func bindWindowPresentation() {
        viewModel.$toastMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self, let message else { return }
                self.toastController.show(message: message)
            }
            .store(in: &cancellables)

        viewModel.$pendingConfirmationAction
            .receive(on: RunLoop.main)
            .sink { [weak self] action in
                guard let self, let action else { return }
                self.presentConfirmation(for: action)
            }
            .store(in: &cancellables)

        viewModel.$liveLogSession
            .receive(on: RunLoop.main)
            .sink { [weak self] session in
                guard let self else { return }
                if let session {
                    self.presentLiveLogsIfNeeded(session)
                } else {
                    self.presentedLogSessionID = nil
                }
            }
            .store(in: &cancellables)
    }

    private func presentConfirmation(for action: DockerPanelAction) {
        guard !isPresentingConfirmation else { return }
        guard let window, let title = action.confirmationTitle else {
            viewModel.confirmPendingAction()
            return
        }

        isPresentingConfirmation = true
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = tr("This action cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("Continue"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingConfirmation = false
            if response == .alertFirstButtonReturn {
                self.viewModel.confirmPendingAction()
            } else {
                self.viewModel.cancelPendingAction()
            }
        }
    }

    private func presentLiveLogsIfNeeded(_ session: DockerLiveLogSession) {
        guard presentedLogSessionID != session.id, let window else { return }
        presentedLogSessionID = session.id
        let controller = NSHostingController(rootView: DockerLiveLogSheet(session: session))
        window.beginSheet(controller.view.window ?? {
            let sheet = NSWindow(contentViewController: controller)
            sheet.styleMask = [.titled, .closable, .resizable]
            sheet.setContentSize(NSSize(width: 820, height: 560))
            sheet.title = session.title
            return sheet
        }()) { [weak self] _ in
            self?.viewModel.dismissLiveLogSession()
        }
    }

    private static func windowTitle(for host: RemoraCore.Host) -> String {
        let hostLabel: String = {
            let trimmed = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            return "\(host.username)@\(host.address):\(host.port)"
        }()

        return String(format: tr("%@ - Docker"), hostLabel)
    }
}

@MainActor
private final class DockerWindowToastController {
    private weak var window: NSWindow?
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    func installIfNeeded(in window: NSWindow) {
        self.window = window
        guard let contentView = window.contentView, label.superview == nil else { return }
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBezeled = false
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 12
        label.layer?.masksToBounds = true
        label.isHidden = true
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            label.heightAnchor.constraint(equalToConstant: 28),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            label.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.72),
        ])
    }

    func show(message: String) {
        guard !message.isEmpty else { return }
        label.stringValue = "  \(message)  "
        label.alphaValue = 0
        label.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            label.animator().alphaValue = 1
        }

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self, !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                self.label.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    self.label.isHidden = true
                }
            }
        }
    }
}

@MainActor
private final class DockerWindowToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    let toolbar = NSToolbar(identifier: "docker-window-toolbar")
    private let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 0))

    var onRefresh: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        searchField.placeholderString = tr("Search")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(equalToConstant: 220),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.dockerRefresh, .flexibleSpace, .dockerSearch]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .dockerRefresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Refresh")
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(handleRefresh)
            return item
        case .dockerSearch:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tr("Search")
            item.view = searchField
            return item
        default:
            return nil
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    @objc private func handleRefresh() {
        onRefresh?()
    }
}

private extension NSToolbarItem.Identifier {
    static let dockerRefresh = NSToolbarItem.Identifier("docker-toolbar-refresh")
    static let dockerSearch = NSToolbarItem.Identifier("docker-toolbar-search")
}
