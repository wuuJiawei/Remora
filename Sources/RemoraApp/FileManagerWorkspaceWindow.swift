import AppKit
import Combine
import SwiftUI
import RemoraCore

@MainActor
final class FileManagerWorkspaceWindowManager: ObservableObject {
    private final class WindowRecord {
        let id: UUID
        let host: RemoraCore.Host
        let runtimeID: ObjectIdentifier
        let viewModel: FileTransferViewModel
        let directorySyncBridge: TerminalDirectorySyncBridge
        let controller: FileManagerWorkspaceWindowController
        let runtimeObserver: AnyCancellable

        init(
            id: UUID,
            host: RemoraCore.Host,
            runtimeID: ObjectIdentifier,
            viewModel: FileTransferViewModel,
            directorySyncBridge: TerminalDirectorySyncBridge,
            controller: FileManagerWorkspaceWindowController,
            runtimeObserver: AnyCancellable
        ) {
            self.id = id
            self.host = host
            self.runtimeID = runtimeID
            self.viewModel = viewModel
            self.directorySyncBridge = directorySyncBridge
            self.controller = controller
            self.runtimeObserver = runtimeObserver
        }
    }

    private var windows: [UUID: WindowRecord] = [:]

    func present(
        host: RemoraCore.Host,
        runtime: TerminalRuntime,
        hostCatalog: HostCatalogStore,
        onManageQuickPaths: @escaping (UUID) -> Void,
        onAddCurrentQuickPath: @escaping (String, UUID) -> Void,
        onOpenDownloadSettings: @escaping () -> Void
    ) {
        let windowID = UUID()
        let cascadeIndex = windows.count
        let runtimeID = ObjectIdentifier(runtime)
        let viewModel = FileTransferViewModel()
        let directorySyncBridge = TerminalDirectorySyncBridge()
        bind(viewModel: viewModel, directorySyncBridge: directorySyncBridge, runtime: runtime, fallbackHost: host)

        let controller = FileManagerWorkspaceWindowController(
            host: host,
            runtime: runtime,
            viewModel: viewModel,
            quickPathsProvider: { runtime in
                let hostID = runtime.reconnectableSSHHost?.id
                return hostCatalog.quickPaths(for: hostID)
            },
            onRunQuickPath: { quickPath in
                viewModel.navigateRemote(to: quickPath.path)
            },
            onManageQuickPaths: { runtime in
                guard let hostID = runtime.reconnectableSSHHost?.id else { return }
                onManageQuickPaths(hostID)
            },
            onAddCurrentQuickPath: { currentPath, runtime in
                guard let hostID = runtime.reconnectableSSHHost?.id else { return }
                onAddCurrentQuickPath(currentPath, hostID)
            },
            onRefreshRemote: { runtime in
                Self.refreshOrReconnect(viewModel: viewModel, runtime: runtime)
            },
            onOpenDownloadSettings: onOpenDownloadSettings,
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
        .sink { [weak self, weak viewModel, weak directorySyncBridge] _, _, _ in
            guard let self, let viewModel, let directorySyncBridge else { return }
            self.bind(
                viewModel: viewModel,
                directorySyncBridge: directorySyncBridge,
                runtime: runtime,
                fallbackHost: host
            )
        }

        windows[windowID] = WindowRecord(
            id: windowID,
            host: host,
            runtimeID: runtimeID,
            viewModel: viewModel,
            directorySyncBridge: directorySyncBridge,
            controller: controller,
            runtimeObserver: runtimeObserver
        )

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bind(
        viewModel: FileTransferViewModel,
        directorySyncBridge: TerminalDirectorySyncBridge,
        runtime: TerminalRuntime,
        fallbackHost: RemoraCore.Host
    ) {
        let binding = makeBinding(from: runtime, fallbackHost: fallbackHost)
        viewModel.bindSFTPClient(
            binding.client,
            bindingKey: binding.bindingKey,
            initialRemoteDirectory: binding.initialRemoteDirectory
        )
        directorySyncBridge.bind(fileTransfer: viewModel, runtime: runtime)
    }

    private static func refreshOrReconnect(
        viewModel: FileTransferViewModel,
        runtime: TerminalRuntime
    ) {
        let decision = SSHRefreshActionDecision.resolve(
            connectionState: runtime.connectionState,
            hasReconnectableHost: runtime.reconnectableSSHHost != nil
        )

        switch decision {
        case .refresh:
            viewModel.performContextAction(.refresh)
        case .reconnect:
            runtime.reconnectSSHSession()
        }
    }

    private func makeBinding(
        from runtime: TerminalRuntime,
        fallbackHost: RemoraCore.Host
    ) -> FileManagerRuntimeBinding {
        if runtime.connectionMode == .ssh, let host = runtime.connectedSSHHost {
            return FileManagerRuntimeBinding(
                client: SystemSFTPClient(
                    host: host,
                    connectionReuseMode: .requireExistingConnection
                ),
                bindingKey: Self.bindingKey(runtime: runtime, host: host),
                initialRemoteDirectory: runtime.workingDirectory ?? "/"
            )
        }

        let disconnectedHost = runtime.reconnectableSSHHost ?? fallbackHost
        return FileManagerRuntimeBinding(
            client: DisconnectedSFTPClient(),
            bindingKey: Self.disconnectedBindingKey(runtime: runtime, host: disconnectedHost),
            initialRemoteDirectory: runtime.workingDirectory ?? "/"
        )
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

    private struct FileManagerRuntimeBinding {
        let client: SFTPClientProtocol
        let bindingKey: String
        let initialRemoteDirectory: String
    }

    private static func bindingKey(runtime: TerminalRuntime, host: RemoraCore.Host) -> String {
        "runtime:\(ObjectIdentifier(runtime))|ssh:\(sftpHostSignature(for: host))"
    }

    private static func disconnectedBindingKey(runtime: TerminalRuntime, host: RemoraCore.Host) -> String {
        "runtime:\(ObjectIdentifier(runtime))|disconnected:\(host.id.uuidString)"
    }

    private static func sftpHostSignature(for host: RemoraCore.Host) -> String {
        [
            host.id.uuidString,
            host.address,
            "\(host.port)",
            host.username,
            host.auth.method.rawValue,
            host.auth.keyReference ?? "",
            host.auth.passwordReference ?? "",
        ].joined(separator: "|")
    }
}

@MainActor
final class FileManagerWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private let host: RemoraCore.Host
    private let onClose: () -> Void

    init(
        host: RemoraCore.Host,
        runtime: TerminalRuntime,
        viewModel: FileTransferViewModel,
        quickPathsProvider: @escaping (TerminalRuntime) -> [HostQuickPath],
        onRunQuickPath: @escaping (HostQuickPath) -> Void,
        onManageQuickPaths: @escaping (TerminalRuntime) -> Void,
        onAddCurrentQuickPath: @escaping (String, TerminalRuntime) -> Void,
        onRefreshRemote: @escaping (TerminalRuntime) -> Void,
        onOpenDownloadSettings: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.host = host
        self.onClose = onClose

        let rootView = FileManagerWorkspaceWindowView(
            runtime: runtime,
            viewModel: viewModel,
            quickPathsProvider: quickPathsProvider,
            onRunQuickPath: onRunQuickPath,
            onManageQuickPaths: onManageQuickPaths,
            onAddCurrentQuickPath: onAddCurrentQuickPath,
            onRefreshRemote: onRefreshRemote,
            onOpenDownloadSettings: onOpenDownloadSettings
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.minSize = NSSize(width: 760, height: 560)
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

        return String(format: tr("%@ - File Manager"), hostLabel)
    }
}

private struct FileManagerWorkspaceWindowView: View {
    @ObservedObject var runtime: TerminalRuntime
    @ObservedObject var viewModel: FileTransferViewModel
    let quickPathsProvider: (TerminalRuntime) -> [HostQuickPath]
    let onRunQuickPath: (HostQuickPath) -> Void
    let onManageQuickPaths: (TerminalRuntime) -> Void
    let onAddCurrentQuickPath: (String, TerminalRuntime) -> Void
    let onRefreshRemote: (TerminalRuntime) -> Void
    let onOpenDownloadSettings: () -> Void

    var body: some View {
        FileManagerPanelView(
            viewModel: viewModel,
            quickPaths: quickPathsProvider(runtime),
            onRunQuickPath: onRunQuickPath,
            onManageQuickPaths: {
                onManageQuickPaths(runtime)
            },
            onAddCurrentQuickPath: { path in
                onAddCurrentQuickPath(path, runtime)
            },
            onRefreshRemote: {
                onRefreshRemote(runtime)
            },
            onEditDownloadPath: onOpenDownloadSettings
        )
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualStyle.rightPanelBackground.ignoresSafeArea())
    }
}
