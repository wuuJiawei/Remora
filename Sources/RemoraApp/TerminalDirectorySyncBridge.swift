import Combine
import Foundation

@MainActor
final class TerminalDirectorySyncBridge: ObservableObject {
    private weak var fileTransfer: FileTransferViewModel?
    private weak var runtime: TerminalRuntime?

    private var syncToggleCancellable: AnyCancellable?
    private var runtimeCancellable: AnyCancellable?
    private var runtimeModeCancellable: AnyCancellable?

    func bind(fileTransfer: FileTransferViewModel, runtime: TerminalRuntime?) {
        self.fileTransfer = fileTransfer

        syncToggleCancellable?.cancel()
        syncToggleCancellable = fileTransfer.$isTerminalDirectorySyncEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.updateRuntimeTrackingState(syncEnabledOverride: enabled)
            }

        attachRuntime(runtime)
    }

    func attachRuntime(_ runtime: TerminalRuntime?) {
        if let currentRuntime = self.runtime, currentRuntime !== runtime {
            currentRuntime.setWorkingDirectoryTrackingEnabled(false)
        }

        self.runtime = runtime

        runtimeCancellable?.cancel()
        runtimeModeCancellable?.cancel()
        guard let runtime else { return }

        runtimeModeCancellable = runtime.$connectionMode
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateRuntimeTrackingState()
            }

        updateRuntimeTrackingState()
        runtimeCancellable = runtime.$workingDirectory
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] path in
                self?.handleRuntimeDirectoryChange(path)
            }
    }

    private func updateRuntimeTrackingState(syncEnabledOverride: Bool? = nil) {
        guard let runtime else { return }
        let shouldSync = (syncEnabledOverride ?? self.isSyncEnabled) && runtime.connectionMode == .ssh
        runtime.setWorkingDirectoryTrackingEnabled(shouldSync)
        guard shouldSync else { return }
        if let currentPath = runtime.workingDirectory {
            syncFileTransfer(to: currentPath)
        }
    }

    private func handleRuntimeDirectoryChange(_ path: String) {
        guard isSyncEnabled else { return }
        guard runtime?.connectionMode == .ssh else { return }

        syncFileTransfer(to: path)
    }

    private func syncFileTransfer(to path: String) {
        guard let fileTransfer else { return }
        if fileTransfer.remoteDirectoryPath != path {
            fileTransfer.navigateRemote(to: path)
        }
    }

    private var isSyncEnabled: Bool {
        fileTransfer?.isTerminalDirectorySyncEnabled == true
    }
}
