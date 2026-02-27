import Combine
import Foundation

@MainActor
final class TerminalDirectorySyncBridge: ObservableObject {
    private weak var fileTransfer: FileTransferViewModel?
    private weak var runtime: TerminalRuntime?

    private var fileTransferCancellable: AnyCancellable?
    private var runtimeCancellable: AnyCancellable?

    private var pendingPathFromFileManager: String?
    private var pendingPathFromRuntime: String?

    func bind(fileTransfer: FileTransferViewModel, runtime: TerminalRuntime?) {
        self.fileTransfer = fileTransfer

        fileTransferCancellable?.cancel()
        fileTransferCancellable = fileTransfer.$remoteDirectoryPath
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] path in
                self?.handleFileManagerDirectoryChange(path)
            }

        attachRuntime(runtime)
    }

    func attachRuntime(_ runtime: TerminalRuntime?) {
        if let currentRuntime = self.runtime, currentRuntime !== runtime {
            currentRuntime.setWorkingDirectoryTrackingEnabled(false)
        }

        self.runtime = runtime

        runtimeCancellable?.cancel()
        guard let runtime else { return }

        runtime.setWorkingDirectoryTrackingEnabled(true)
        runtimeCancellable = runtime.$workingDirectory
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] path in
                self?.handleRuntimeDirectoryChange(path)
            }
    }

    private func handleFileManagerDirectoryChange(_ path: String) {
        guard let runtime else { return }
        guard runtime.connectionMode == .ssh else { return }

        if pendingPathFromRuntime == path {
            pendingPathFromRuntime = nil
            return
        }

        pendingPathFromFileManager = path
        runtime.changeDirectory(to: path)
    }

    private func handleRuntimeDirectoryChange(_ path: String) {
        guard runtime?.connectionMode == .ssh else { return }

        if pendingPathFromFileManager == path {
            pendingPathFromFileManager = nil
            return
        }

        guard let fileTransfer else { return }
        pendingPathFromRuntime = path
        if fileTransfer.remoteDirectoryPath != path {
            fileTransfer.navigateRemote(to: path)
        }
    }
}
