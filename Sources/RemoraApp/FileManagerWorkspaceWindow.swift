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
                let hostID = runtime.reconnectableSSHHost?.id ?? host.id
                return hostCatalog.quickPaths(for: hostID)
            },
            onRunQuickPath: { quickPath in
                viewModel.navigateRemote(to: quickPath.path)
            },
            onAddQuickPath: { name, path, runtime in
                let hostID = runtime.reconnectableSSHHost?.id ?? host.id
                return hostCatalog.addQuickPath(hostID: hostID, name: name, path: path)
            },
            onRenameQuickPath: { quickPath, name, runtime in
                let hostID = runtime.reconnectableSSHHost?.id ?? host.id
                return hostCatalog.updateQuickPath(
                    hostID: hostID,
                    quickPath: HostQuickPath(id: quickPath.id, name: name, path: quickPath.path)
                )
            },
            onDeleteQuickPath: { quickPath, runtime in
                let hostID = runtime.reconnectableSSHHost?.id ?? host.id
                hostCatalog.deleteQuickPath(hostID: hostID, quickPathID: quickPath.id)
            },
            onReorderQuickPaths: { orderedIDs, runtime in
                let hostID = runtime.reconnectableSSHHost?.id ?? host.id
                hostCatalog.reorderQuickPaths(hostID: hostID, orderedQuickPathIDs: orderedIDs)
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
    private let toolbarController = FileManagerWindowToolbar()
    private var toolbarCancellables: Set<AnyCancellable> = []
    private let splitController: FileManagerWindowSplitController
    private let remoteEditorWindowManager: RemoteTextEditorWindowManager
    private let remoteLiveLogWindowManager: RemoteLiveLogWindowManager

    init(
        host: RemoraCore.Host,
        runtime: TerminalRuntime,
        viewModel: FileTransferViewModel,
        quickPathsProvider: @escaping (TerminalRuntime) -> [HostQuickPath],
        onRunQuickPath: @escaping (HostQuickPath) -> Void,
        onAddQuickPath: @escaping (String, String, TerminalRuntime) -> HostQuickPath?,
        onRenameQuickPath: @escaping (HostQuickPath, String, TerminalRuntime) -> HostQuickPath?,
        onDeleteQuickPath: @escaping (HostQuickPath, TerminalRuntime) -> Void,
        onReorderQuickPaths: @escaping ([UUID], TerminalRuntime) -> Void,
        onRefreshRemote: @escaping (TerminalRuntime) -> Void,
        onOpenDownloadSettings: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.host = host
        self.onClose = onClose
        self.remoteEditorWindowManager = RemoteTextEditorWindowManager(fileTransfer: viewModel)
        self.remoteLiveLogWindowManager = RemoteLiveLogWindowManager(fileTransfer: viewModel)

        self.splitController = FileManagerWindowSplitController(
            selectedPath: viewModel.remoteDirectoryPath,
            quickPathsProvider: {
                quickPathsProvider(runtime)
            },
            directoriesProvider: {
                viewModel.remoteEntries.filter(\.isDirectory)
            },
            onSelectRoot: {
                viewModel.navigateRemote(to: "/")
            },
            onSelectQuickPath: onRunQuickPath,
            onSelectDirectory: { path in
                viewModel.navigateRemote(to: path)
            },
            onAddQuickPathForDirectory: { path in
                _ = onAddQuickPath(path, path, runtime)
            },
            onRenameQuickPath: { quickPath in
                _ = onRenameQuickPath(quickPath, quickPath.name, runtime)
            },
            onDeleteQuickPath: { quickPath in
                onDeleteQuickPath(quickPath, runtime)
            },
            onReorderQuickPaths: { orderedIDs in
                onReorderQuickPaths(orderedIDs, runtime)
            },
            onRefreshDirectory: { path in
                if viewModel.remoteDirectoryPath == path {
                    onRefreshRemote(runtime)
                } else {
                    viewModel.navigateRemote(to: path)
                }
            },
            onOpenDirectory: { entry in
                viewModel.openRemote(entry)
            },
            onRefreshCurrentDirectory: {
                onRefreshRemote(runtime)
            },
            onAddCurrentQuickPath: { path in
                _ = onAddQuickPath(path, path, runtime)
            },
            onCreateDirectory: { path in
                let alert = NSAlert()
                alert.messageText = tr("New Folder")
                alert.informativeText = tr("Name")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                field.stringValue = tr("New Folder")
                alert.accessoryView = field
                alert.addButton(withTitle: tr("Create"))
                alert.addButton(withTitle: tr("Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    viewModel.createRemoteDirectory(named: name, in: path)
                }
            },
            onCreateFile: { path in
                let alert = NSAlert()
                alert.messageText = tr("New File")
                alert.informativeText = tr("Name")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                field.stringValue = "untitled.txt"
                alert.accessoryView = field
                alert.addButton(withTitle: tr("Create"))
                alert.addButton(withTitle: tr("Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    viewModel.createRemoteFile(named: name, in: path)
                }
            },
            onRenameEntry: { entry in
                let alert = NSAlert()
                alert.messageText = tr("Rename")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                field.stringValue = entry.name
                alert.accessoryView = field
                alert.addButton(withTitle: tr("Save"))
                alert.addButton(withTitle: tr("Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty else { return }
                    viewModel.renameRemoteEntry(path: entry.path, toName: newName)
                }
            },
            onDeleteEntries: { entries in
                viewModel.deleteRemoteEntries(paths: entries.map(\.path))
            },
            onCopyPath: { path in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(path, forType: .string)
            },
            onUploadToDirectory: { path in
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = true
                panel.canChooseFiles = true
                panel.canCreateDirectories = false
                if panel.runModal() == .OK {
                    let acceptedURLs = RemoteDropRouting.acceptedLocalDropURLs(panel.urls)
                    guard !acceptedURLs.isEmpty else { return }
                    viewModel.enqueueUpload(localFileURLs: acceptedURLs, toRemoteDirectory: path)
                }
            }
        )

        toolbarController.onBack = {
            viewModel.navigateRemoteBack()
        }
        toolbarController.onForward = {
            viewModel.navigateRemoteForward()
        }
        toolbarController.onRefresh = {
            onRefreshRemote(runtime)
        }
        toolbarController.onPathSelected = { path in
            viewModel.navigateRemote(to: path)
        }

        let window = NSWindow(contentViewController: splitController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.title = Self.windowTitle(for: host)
        window.toolbar = toolbarController.toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        super.init(window: window)
        window.delegate = self
        toolbarController.update(
            currentPath: viewModel.remoteDirectoryPath,
            canGoBack: viewModel.canNavigateRemoteBack,
            canGoForward: viewModel.canNavigateRemoteForward
        )
        toolbarController.onSearchChanged = { [weak self, weak viewModel] query in
            guard let self, let viewModel else { return }
            self.splitController.updateSearchQuery(query)
            self.splitController.reloadDetail(
                currentPath: viewModel.remoteDirectoryPath,
                entries: viewModel.remoteEntries,
                isLoading: viewModel.isRemoteLoading,
                searchQuery: query
            )
        }
        splitController.setPropertyHandlers(
            onShowProperties: { [weak self] entry in
                guard let self else { return }
                let controller = NSHostingController(
                    rootView: RemoteFilePropertiesSheet(
                        path: entry.path,
                        fileTransfer: viewModel,
                        initialAttributes: RemoteFileAttributes(
                            permissions: entry.permissions,
                            owner: entry.owner,
                            group: entry.group,
                            size: entry.size,
                            modifiedAt: entry.modifiedAt,
                            isDirectory: entry.isDirectory
                        )
                    )
                )
                let sheet = NSWindow(contentViewController: controller)
                sheet.styleMask = [.titled, .closable]
                sheet.setContentSize(NSSize(width: 420, height: 320))
                self.window?.beginSheet(sheet)
            },
            onEditPermissions: { [weak self] entry in
                guard let self else { return }
                let controller = NSHostingController(
                    rootView: RemotePermissionsEditorSheet(
                        path: entry.path,
                        fileTransfer: viewModel,
                        initialAttributes: RemoteFileAttributes(
                            permissions: entry.permissions,
                            owner: entry.owner,
                            group: entry.group,
                            size: entry.size,
                            modifiedAt: entry.modifiedAt,
                            isDirectory: entry.isDirectory
                        )
                    )
                )
                let sheet = NSWindow(contentViewController: controller)
                sheet.styleMask = [.titled, .closable]
                sheet.setContentSize(NSSize(width: 420, height: 360))
                self.window?.beginSheet(sheet)
            }
        )
        splitController.setOpenHandlers(
            onOpenTextFile: { [weak self] entry in
                self?.remoteEditorWindowManager.present(
                    path: entry.path,
                    loadOptions: RemoteTextDocumentLoadOptions(
                        knownSize: entry.size,
                        knownModifiedAt: entry.modifiedAt
                    )
                )
            },
            onOpenLogView: { [weak self] entry in
                self?.remoteLiveLogWindowManager.present(path: entry.path)
            }
        )
        splitController.setArchiveHandlers(
            onCompressEntries: { [weak self, weak viewModel] entries in
                guard let self, let viewModel else { return }
                let paths = entries.map(\.path)
                let baseName = entries.count == 1
                    ? URL(fileURLWithPath: entries[0].path).lastPathComponent
                    : tr("Archive")
                let archiveName = ArchiveSupport.defaultArchiveName(for: baseName, format: .zip)
                Task {
                    do {
                        try await viewModel.compressRemoteEntries(
                            paths: paths,
                            archiveName: archiveName,
                            format: .zip,
                            destinationDirectory: viewModel.remoteDirectoryPath
                        )
                    } catch {
                        await MainActor.run {
                            let alert = NSAlert(error: error)
                            if let window = self.window {
                                alert.beginSheetModal(for: window)
                            }
                        }
                    }
                }
            },
            onExtractEntry: { [weak self, weak viewModel] entry in
                guard let self, let viewModel else { return }
                Task {
                    do {
                        try await viewModel.extractRemoteArchive(path: entry.path, into: viewModel.remoteDirectoryPath)
                    } catch {
                        await MainActor.run {
                            let alert = NSAlert(error: error)
                            if let window = self.window {
                                alert.beginSheetModal(for: window)
                            }
                        }
                    }
                }
            }
        )
        bindToolbar(viewModel: viewModel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func bindToolbar(viewModel: FileTransferViewModel) {
        viewModel.$remoteDirectoryPath
            .combineLatest(viewModel.$canNavigateRemoteBack, viewModel.$canNavigateRemoteForward)
            .receive(on: RunLoop.main)
            .sink { [weak self] path, canGoBack, canGoForward in
                self?.toolbarController.update(
                    currentPath: path,
                    canGoBack: canGoBack,
                    canGoForward: canGoForward
                )
                self?.splitController.reloadSidebar(selectedPath: path)
                self?.splitController.reloadDetail(
                    currentPath: path,
                    entries: viewModel.remoteEntries,
                    isLoading: viewModel.isRemoteLoading,
                    searchQuery: self?.splitController.currentSearchQuery ?? ""
                )
            }
            .store(in: &toolbarCancellables)

        viewModel.$remoteEntries
            .combineLatest(viewModel.$isRemoteLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] entries, isLoading in
                guard let self, let viewModel else { return }
                self.splitController.reloadDetail(
                    currentPath: viewModel.remoteDirectoryPath,
                    entries: entries,
                    isLoading: isLoading,
                    searchQuery: self.splitController.currentSearchQuery
                )
            }
            .store(in: &toolbarCancellables)
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
