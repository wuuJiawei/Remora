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

    init(
        host: RemoraCore.Host,
        viewModel: DockerPanelViewModel,
        onOpenContainerShell: @escaping (DockerContainer) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.host = host
        self.viewModel = viewModel
        self.onClose = onClose

        let rootView = DockerPanelView(
            viewModel: viewModel,
            onOpenContainerShell: onOpenContainerShell
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 720))
        window.minSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.title = Self.windowTitle(for: host)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
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
