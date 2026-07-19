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
        LogManager.info(.fileManager, "present window host=\(host.name) path=\(runtime.workingDirectory ?? "/")")
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

        LogManager.info(.fileManager, "show window id=\(windowID.uuidString)")
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
        LogManager.info(
            .fileManager,
            "bind runtimeMode=\(runtime.connectionMode.rawValue) state=\(runtime.connectionState) workingDir=\(runtime.workingDirectory ?? "/")"
        )
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
                client: SystemSFTPClient(host: host),
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
    private enum ExtractDestinationMode {
        case currentDirectory
        case sameNameDirectory
        case custom
    }

    private let host: RemoraCore.Host
    private let onClose: () -> Void
    private let toolbarController = FileManagerWindowToolbar()
    private var toolbarCancellables: Set<AnyCancellable> = []
    private let splitController: FileManagerWindowSplitController
    private let toastController = FileManagerWindowToastController()
    private var downloadsPopover: NSPopover?
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
        var refreshQuickPaths: (() -> Void)?
        var copyPathHandler: ((String) -> Void)?
        var toolbarCopyPathHandler: ((String) -> Void)?
        var copyEntriesHandler: (([RemoteFileEntry]) -> Void)?
        var cutEntriesHandler: (([RemoteFileEntry]) -> Void)?
        var pasteEntriesHandler: ((String) -> Void)?
        var cloneEntryHandler: ((RemoteFileEntry) -> Void)?
        var moveEntriesHandler: (([RemoteFileEntry]) -> Void)?

        self.splitController = FileManagerWindowSplitController(
            selectedPath: viewModel.remoteDirectoryPath,
            quickPathsProvider: {
                quickPathsProvider(runtime)
            },
            directoryChildrenProvider: { path in
                do {
                    return try await viewModel.listRemoteDirectory(path: path, preferCachedFirst: true)
                        .filter(\.isDirectory)
                } catch {
                    LogManager.error(.fileManager, "sidebar list failed path=\(path) error=\(error.localizedDescription)")
                    return []
                }
            },
            onSelectRoot: {
                viewModel.navigateRemote(to: "/")
            },
            onSelectQuickPath: onRunQuickPath,
            onSelectDirectory: { path in
                viewModel.navigateRemote(to: path)
            },
            onAddQuickPathForDirectory: { path in
                if onAddQuickPath(path, path, runtime) != nil {
                    refreshQuickPaths?()
                }
            },
            onRenameQuickPath: { quickPath in
                _ = onRenameQuickPath(quickPath, quickPath.name, runtime)
            },
            onDeleteQuickPath: { quickPath in
                onDeleteQuickPath(quickPath, runtime)
                refreshQuickPaths?()
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
                if onAddQuickPath(path, path, runtime) != nil {
                    refreshQuickPaths?()
                }
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
            onDownloadEntries: { entries in
                for entry in entries {
                    viewModel.enqueueDownload(remoteEntry: entry)
                }
            },
            onCopyEntries: { entries in
                copyEntriesHandler?(entries)
            },
            onCutEntries: { entries in
                cutEntriesHandler?(entries)
            },
            canPasteIntoDirectory: { path in
                viewModel.canPaste(into: path)
            },
            onPasteIntoDirectory: { path in
                pasteEntriesHandler?(path)
            },
            onCloneEntry: { entry in
                cloneEntryHandler?(entry)
            },
            onMoveEntries: { entries in
                moveEntriesHandler?(entries)
            },
            onCopyPath: { path in
                copyPathHandler?(path)
            },
            onOpenInTerminal: { path in
                runtime.changeDirectory(to: path)
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
            },
            onUploadLocalFiles: { urls, path in
                let acceptedURLs = RemoteDropRouting.acceptedLocalDropURLs(urls)
                guard !acceptedURLs.isEmpty else { return }
                viewModel.enqueueUpload(localFileURLs: acceptedURLs, toRemoteDirectory: path)
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
        toolbarController.onCopyCurrentPath = { path in
            toolbarCopyPathHandler?(path)
        }
        toolbarController.onTerminalSyncToggled = {
            viewModel.isTerminalDirectorySyncEnabled.toggle()
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
        toastController.installIfNeeded(in: window)
        copyPathHandler = { [weak self] path in
            self?.copyPathToPasteboard(path)
        }
        toolbarCopyPathHandler = { [weak self] path in
            self?.copyPathToPasteboard(path)
        }
        copyEntriesHandler = { [weak self] entries in
            viewModel.copyRemoteEntries(paths: entries.map(\.path), mode: .copy)
            self?.toastController.show(message: String(format: tr("Copied %d item(s)."), entries.count))
        }
        cutEntriesHandler = { [weak self] entries in
            viewModel.copyRemoteEntries(paths: entries.map(\.path), mode: .cut)
            self?.toastController.show(message: String(format: tr("Cut %d item(s)."), entries.count))
        }
        pasteEntriesHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await viewModel.pasteRemoteEntriesResult(into: path)
                switch result {
                case .blockedCrossConnection:
                    self.toastController.show(message: tr("Cross-server paste is not supported yet."))
                case .success(let destinationDirectory, let pastedCount, _):
                    guard pastedCount > 0 else { return }
                    self.toastController.show(
                        message: String(format: tr("Pasted into %@."), destinationDirectory)
                    )
                }
            }
        }
        cloneEntryHandler = { [weak self] entry in
            viewModel.cloneRemoteEntry(path: entry.path)
            self?.toastController.show(message: String(format: tr("%@ Copy"), entry.name))
        }
        moveEntriesHandler = { [weak self] entries in
            guard let self else { return }
            self.presentMoveEntriesPrompt(entries: entries, viewModel: viewModel)
        }
        refreshQuickPaths = { [weak self] in
            self?.splitController.refreshSidebarQuickPaths()
        }
        toolbarController.onDownloadsClicked = { [weak self] in
            self?.toggleDownloadsPopover(viewModel: viewModel)
        }
        toolbarController.update(
            currentPath: viewModel.remoteDirectoryPath,
            canGoBack: viewModel.canNavigateRemoteBack,
            canGoForward: viewModel.canNavigateRemoteForward
        )
        toolbarController.updateDownloads(
            progress: viewModel.overallTransferProgress,
            hasHistory: !viewModel.transferQueue.isEmpty,
            status: transferQueueStatus(for: viewModel)
        )
        toolbarController.updateTerminalSync(isEnabled: viewModel.isTerminalDirectorySyncEnabled)
        toolbarController.onSearchChanged = { [weak self, weak viewModel] query in
            guard let self, let viewModel else { return }
            self.splitController.updateSearchQuery(query)
            self.splitController.reloadDetail(
                currentPath: viewModel.remoteDirectoryPath,
                entries: viewModel.remoteEntries,
                isLoading: viewModel.isRemoteLoading,
                searchQuery: query,
                transferProgress: viewModel.overallTransferProgress
            )
        }
        splitController.setPropertyHandlers(
            onShowProperties: { [weak self] entry in
                guard let self else { return }
                let sheet = NSWindow()
                let controller = NSHostingController(
                    rootView: RemoteFilePropertiesSheet(
                        path: entry.path,
                        fileTransfer: viewModel,
                        onClose: { [weak self] in
                            guard let self else { return }
                            self.window?.endSheet(sheet)
                        },
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
                sheet.contentViewController = controller
                sheet.styleMask = [.titled, .closable]
                sheet.setContentSize(NSSize(width: 420, height: 320))
                self.window?.beginSheet(sheet)
            },
            onEditPermissions: { [weak self] entry in
                guard let self else { return }
                let sheet = NSWindow()
                let controller = NSHostingController(
                    rootView: RemotePermissionsEditorSheet(
                        path: entry.path,
                        fileTransfer: viewModel,
                        onClose: { [weak self] in
                            guard let self else { return }
                            self.window?.endSheet(sheet)
                        },
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
                sheet.contentViewController = controller
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
            onCompressEntries: { [weak self, weak viewModel] entries, format in
                guard let self, let viewModel else { return }
                self.presentRemoteCompressSheet(entries: entries, initialFormat: format, viewModel: viewModel)
            },
            onExtractEntry: { [weak self, weak viewModel] entry, action in
                guard let self, let viewModel else { return }
                let mode: ExtractDestinationMode = switch action {
                case .currentDirectory:
                    .currentDirectory
                case .sameNameDirectory:
                    .sameNameDirectory
                case .customDirectory:
                    .custom
                }
                self.presentRemoteExtractSheet(entry: entry, mode: mode, viewModel: viewModel)
            }
        )
        bindToolbar(viewModel: viewModel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        toastController.dismissImmediately()
        onClose()
    }

    private func copyPathToPasteboard(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmedPath, forType: .string)
        toastController.show(message: tr("Path copied to clipboard."))
    }

    private func bindToolbar(viewModel: FileTransferViewModel) {
        viewModel.$isTerminalDirectorySyncEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.toolbarController.updateTerminalSync(isEnabled: isEnabled)
            }
            .store(in: &toolbarCancellables)

        viewModel.$remoteDirectoryPath
            .combineLatest(viewModel.$canNavigateRemoteBack, viewModel.$canNavigateRemoteForward)
            .receive(on: RunLoop.main)
            .sink { [weak self] path, canGoBack, canGoForward in
                self?.toolbarController.update(
                    currentPath: path,
                    canGoBack: canGoBack,
                    canGoForward: canGoForward
                )
                self?.splitController.updateSidebarSelection(selectedPath: path)
                self?.splitController.reloadDetail(
                    currentPath: path,
                    entries: viewModel.remoteEntries,
                    isLoading: viewModel.isRemoteLoading,
                    searchQuery: self?.splitController.currentSearchQuery ?? "",
                    transferProgress: viewModel.overallTransferProgress
                )
            }
            .store(in: &toolbarCancellables)

        viewModel.$remoteEntries
            .combineLatest(viewModel.$isRemoteLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] entries, isLoading in
                guard let self, let viewModel else { return }
                self.splitController.updateSidebarDirectorySnapshot(
                    path: viewModel.remoteDirectoryPath,
                    entries: entries
                )
                self.splitController.reloadDetail(
                    currentPath: viewModel.remoteDirectoryPath,
                    entries: entries,
                    isLoading: isLoading,
                    searchQuery: self.splitController.currentSearchQuery,
                    transferProgress: viewModel.overallTransferProgress
                )
            }
            .store(in: &toolbarCancellables)

        viewModel.$transferQueue
            .combineLatest(viewModel.$currentTransferBatchID)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] queue, _ in
                guard let self, let viewModel else { return }
                self.toolbarController.updateDownloads(
                    progress: viewModel.overallTransferProgress,
                    hasHistory: !queue.isEmpty,
                    status: self.transferQueueStatus(for: viewModel)
                )
                self.refreshDownloadsPopover(viewModel: viewModel)
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

    private func toggleDownloadsPopover(viewModel: FileTransferViewModel) {
        if let downloadsPopover, downloadsPopover.isShown {
            downloadsPopover.performClose(nil)
            return
        }

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 420, height: 340)
        popover.contentViewController = NSHostingController(
            rootView: FileManagerDownloadsPopoverView(
                viewModel: viewModel,
                onOpenDownloadSettings: { [weak self] in
                    self?.showDownloadSettings()
                }
            )
        )
        popover.show(relativeTo: toolbarController.downloadsAnchorView.bounds, of: toolbarController.downloadsAnchorView, preferredEdge: .maxY)
        downloadsPopover = popover
    }

    private func refreshDownloadsPopover(viewModel: FileTransferViewModel) {
        guard let downloadsPopover, downloadsPopover.isShown else { return }
    }

    private func transferQueueStatus(for viewModel: FileTransferViewModel) -> TransferQueueAggregateStatus {
        TransferQueueAggregateSnapshot.resolve(
            items: viewModel.transferQueue,
            currentBatchID: viewModel.currentTransferBatchID,
            runningFallbackProgress: 0.1
        ).status
    }

    private func showDownloadSettings() {
        NotificationCenter.default.post(name: .remoraOpenSettingsCommand, object: nil)
        NotificationCenter.default.post(name: .remoraOpenDownloadDirectorySetting, object: nil)
    }

    private func presentRemoteCompressSheet(
        entries: [RemoteFileEntry],
        initialFormat: ArchiveFormat,
        viewModel: FileTransferViewModel
    ) {
        let paths = entries.map(\.path)
        let destinationDirectory = paths.first
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            .map { $0.isEmpty ? "/" : $0 }
            ?? viewModel.remoteDirectoryPath
        let archiveName = RemoteArchiveCommandBuilder.defaultArchiveName(
            for: paths,
            currentDirectory: destinationDirectory,
            format: initialFormat
        )
        let archiveNameBox = ObservableBox(archiveName)
        let formatBox = ObservableBox(initialFormat)
        let sheet = NSWindow()
        let controller = NSHostingController(
            rootView: RemoteCompressSheet(
                sourcePaths: paths,
                fileTransfer: viewModel,
                archiveName: archiveNameBox.binding,
                format: formatBox.binding,
                onConfirm: { [weak self] in
                    guard let self else { return }
                    let chosenName = archiveNameBox.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !chosenName.isEmpty else { return }
                    let chosenFormat = formatBox.value
                    Task {
                        do {
                            try await viewModel.compressRemoteEntries(
                                paths: paths,
                                archiveName: chosenName,
                                format: chosenFormat,
                                destinationDirectory: destinationDirectory
                            )
                            await MainActor.run {
                                self.window?.endSheet(sheet)
                                self.toastController.show(message: tr("Archive created."))
                            }
                        } catch {
                            await MainActor.run {
                                self.presentArchiveError(error, viewModel: viewModel)
                            }
                        }
                    }
                }
            )
        )
        sheet.contentViewController = controller
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 420, height: 250))
        window?.beginSheet(sheet)
    }

    private func presentRemoteExtractSheet(
        entry: RemoteFileEntry,
        mode: ExtractDestinationMode,
        viewModel: FileTransferViewModel
    ) {
        guard let format = ArchiveFormat.extractFormat(for: entry.path) else {
            presentArchiveError(ArchiveSupportError.unsupportedExtractionFormat, viewModel: viewModel)
            return
        }
        let destinationPath: String = switch mode {
        case .currentDirectory:
            viewModel.remoteDirectoryPath
        case .sameNameDirectory:
            RemoteArchiveCommandBuilder.sameNameDirectory(for: entry.path, format: format)
        case .custom:
            viewModel.remoteDirectoryPath
        }
        let destinationBox = ObservableBox(destinationPath)
        let sheet = NSWindow()
        let controller = NSHostingController(
            rootView: RemoteExtractSheet(
                archivePath: entry.path,
                fileTransfer: viewModel,
                destinationPath: destinationBox.binding,
                onConfirm: { [weak self] in
                    guard let self else { return }
                    let targetPath = destinationBox.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !targetPath.isEmpty else { return }
                    Task {
                        do {
                            try await viewModel.extractRemoteArchive(path: entry.path, into: targetPath)
                            await MainActor.run {
                                self.window?.endSheet(sheet)
                                self.toastController.show(message: tr("Archive extracted."))
                            }
                        } catch {
                            await MainActor.run {
                                self.presentArchiveError(error, viewModel: viewModel)
                            }
                        }
                    }
                }
            )
        )
        sheet.contentViewController = controller
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 460, height: 220))
        window?.beginSheet(sheet)
    }

    private func presentArchiveError(_ error: Error, viewModel: FileTransferViewModel) {
        if let archiveError = error as? ArchiveSupportError,
           case let .missingRemoteTool(context) = archiveError {
            presentMissingArchiveToolAlert(context: context, viewModel: viewModel)
            return
        }
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        }
    }

    private func presentMoveEntriesPrompt(
        entries: [RemoteFileEntry],
        viewModel: FileTransferViewModel
    ) {
        let sheet = NSWindow()
        let controller = NSHostingController(
            rootView: RemoteDirectoryChooserSheet(
                initialPath: viewModel.remoteDirectoryPath,
                fileTransfer: viewModel,
                onCancel: { [weak self] in
                    self?.window?.endSheet(sheet)
                },
                onConfirm: { [weak self] destination in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let movedCount = await viewModel.moveRemoteEntriesResult(
                            paths: entries.map(\.path),
                            toDirectory: destination
                        )
                        self.window?.endSheet(sheet)
                        guard movedCount > 0 else { return }
                        self.toastController.show(
                            message: String(format: tr("Moved %d item(s) to %@."), movedCount, destination)
                        )
                    }
                }
            )
        )
        sheet.contentViewController = controller
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 460, height: 420))
        window?.beginSheet(sheet)
    }

    private func presentMissingArchiveToolAlert(
        context: RemoteArchiveMissingToolContext,
        viewModel: FileTransferViewModel
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: tr("Current server is missing %@"),
            context.tool
        )
        alert.informativeText = String(
            format: tr("%@\n\nInstall hint:\n%@"),
            context.actionDescription,
            context.installHint
        )
        alert.addButton(withTitle: tr("Copy Install Command"))
        alert.addButton(withTitle: tr("Install Now"))
        alert.addButton(withTitle: tr("Cancel"))

        guard let window else {
            let response = alert.runModal()
            handleMissingArchiveToolAlertResponse(response, context: context, viewModel: viewModel)
            return
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            self?.handleMissingArchiveToolAlertResponse(response, context: context, viewModel: viewModel)
        }
    }

    private func handleMissingArchiveToolAlertResponse(
        _ response: NSApplication.ModalResponse,
        context: RemoteArchiveMissingToolContext,
        viewModel: FileTransferViewModel
    ) {
        switch response {
        case .alertFirstButtonReturn:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(context.installCommand, forType: .string)
            toastController.show(message: tr("Install command copied to clipboard."))
        case .alertSecondButtonReturn:
            Task { [weak self] in
                do {
                    _ = try await viewModel.executeArchiveInstallCommand(context.installCommand)
                    _ = try await viewModel.refreshRemoteArchiveToolchain()
                    await MainActor.run {
                        self?.toastController.show(message: tr("Remote archive tools refreshed."))
                    }
                } catch {
                    await MainActor.run {
                        self?.presentArchiveError(error, viewModel: viewModel)
                    }
                }
            }
        default:
            break
        }
    }
}

@MainActor
private final class ObservableBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var binding: Binding<Value> {
        Binding(
            get: { self.value },
            set: { self.value = $0 }
        )
    }
}

@MainActor
private final class FileManagerWindowToastController {
    private weak var window: NSWindow?
    private weak var toastLabel: NSTextField?
    private var hideTask: Task<Void, Never>?

    func installIfNeeded(in window: NSWindow) {
        self.window = window
        if toastLabel != nil {
            return
        }
        guard let contentView = window.contentView else { return }

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        label.alphaValue = 0
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.wantsLayer = true
        label.layer?.cornerRadius = 10
        label.layer?.cornerCurve = .continuous
        label.layer?.borderWidth = 1
        label.layer?.masksToBounds = true
        updateToastAppearance(for: label)

        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
        ])
        toastLabel = label
    }

    func show(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let label = toastLabel else { return }

        hideTask?.cancel()
        updateToastAppearance(for: label)
        label.stringValue = trimmed
        label.isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            label.animator().alphaValue = 1
        }

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.hideAnimated()
        }
    }

    func dismissImmediately() {
        hideTask?.cancel()
        hideTask = nil
        toastLabel?.alphaValue = 0
        toastLabel?.isHidden = true
    }

    private func hideAnimated() {
        guard let label = toastLabel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            label.animator().alphaValue = 0
        })
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.18))
            guard !Task.isCancelled else { return }
            label.isHidden = true
        }
        hideTask = nil
    }

    private func updateToastAppearance(for label: NSTextField) {
        guard let appearance = window?.effectiveAppearance else { return }
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        label.drawsBackground = true
        label.backgroundColor = isDark
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.94)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.94)
        label.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        label.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.28 : 0.12)
            return shadow
        }()
    }
}
