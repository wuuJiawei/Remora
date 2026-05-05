import AppKit
import SwiftUI

@MainActor
final class RemoteTextEditorWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    private final class WindowRecord {
        let path: String
        let viewModel: RemoteTextEditorViewModel
        let window: NSWindow

        init(path: String, viewModel: RemoteTextEditorViewModel, window: NSWindow) {
            self.path = path
            self.viewModel = viewModel
            self.window = window
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
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = RemoteTextEditorViewModel(
            path: normalizedPath,
            loadOptions: loadOptions,
            fileTransfer: fileTransfer
        )
        let rootView = RemoteTextEditorWindowView(viewModel: viewModel) { [weak self] in
            self?.refreshWindowTitle(for: normalizedPath)
        }
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("remora.remote-editor.\(normalizedPath)")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .preferred
        applyAppearanceMode(to: window)

        let record = WindowRecord(path: normalizedPath, viewModel: viewModel, window: window)
        windows[normalizedPath] = record
        refreshWindowTitle(for: normalizedPath)
        positionWindowNearPrimaryWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshWindowTitle(for path: String) {
        guard let record = windows[path] else { return }
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
        record.window.title = prefix + fileName
        record.window.isDocumentEdited = record.viewModel.isDirty
        EditorDebugLog.log("window.title path=\(path) title=\(record.window.title)")
    }

    private func applyAppearanceMode(to window: NSWindow) {
        let rawValue = AppPreferences.shared.value(for: \.appearanceModeRawValue)
        let mode = AppAppearanceMode.resolved(from: rawValue)
        if let appearanceName = mode.nsAppearanceName {
            window.appearance = NSAppearance(named: appearanceName)
        } else {
            window.appearance = nil
        }
    }

    private func positionWindowNearPrimaryWindow(_ window: NSWindow) {
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
        guard let record = windows.values.first(where: { $0.window === sender }) else { return true }
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
        windows = windows.filter { $0.value.window !== window }
    }
}

struct RemoteTextEditorWindowView: View {
    @StateObject private var viewModel: RemoteTextEditorViewModel
    private let onWindowStateChange: () -> Void

    init(viewModel: RemoteTextEditorViewModel, onWindowStateChange: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onWindowStateChange = onWindowStateChange
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemoteTextEditorRepresentable(
                descriptor: viewModel.documentDescriptor,
                initialContent: viewModel.initialContent,
                saveRequestID: viewModel.saveRequestID,
                savedRevision: viewModel.lastSavedRevision,
                onChange: { revision in
                    viewModel.markDirty(revision: revision)
                    onWindowStateChange()
                },
                onSaveRequested: { request in
                    Task {
                        await viewModel.save(request: request)
                        onWindowStateChange()
                    }
                },
                onError: { message in
                    viewModel.errorMessage = message
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
            }

            if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.88))
                    )
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task {
            await viewModel.load()
            onWindowStateChange()
        }
        .onChange(of: viewModel.saveStatus) { _, _ in
            onWindowStateChange()
        }
        .onChange(of: viewModel.isDirty) { _, _ in
            onWindowStateChange()
        }
    }
}
