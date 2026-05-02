import Foundation
import AppKit
import RemoraCore

// MARK: - ZMODEM Transfer Coordinator

@MainActor
final class ZmodemTransferCoordinator: ObservableObject {
    @Published var isActive = false
    @Published var fileName: String = ""
    @Published var fileSize: Int64?
    @Published var bytesTransferred: Int64 = 0
    @Published var finished = false
    @Published var errorMessage: String?

    private var receiveEngine: ZmodemReceiveEngine?
    private var sendEngine: ZmodemSendEngine?
    private var writeToSession: ((Data) async throws -> Void)?

    /// Serial write queue to guarantee ordering of protocol messages
    private var pendingWrites: [Data] = []
    private var isWriting = false

    // MARK: - Receive (sz download)

    func startReceive(initialData: Data, writer: @escaping (Data) async throws -> Void) {
        resetState()
        isActive = true
        writeToSession = writer

        let engine = ZmodemReceiveEngine { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleEvent(event)
            }
        }
        self.receiveEngine = engine
        engine.feedOutput(initialData)
    }

    // MARK: - Send (rz upload)

    func startSend(initialData: Data, writer: @escaping (Data) async throws -> Void) {
        resetState()
        isActive = true
        writeToSession = writer

        let engine = ZmodemSendEngine { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleEvent(event)
            }
        }
        self.sendEngine = engine
        engine.feedOutput(initialData)

        presentOpenPanel { [weak self] urls in
            guard let self, self.sendEngine === engine else { return }
            if let urls, !urls.isEmpty {
                engine.setFiles(urls)
            } else {
                self.cancelTransfer()
            }
        }
    }

    // MARK: - Common

    func feedOutput(_ data: Data) {
        receiveEngine?.feedOutput(data)
        sendEngine?.feedOutput(data)
    }

    func cancelTransfer() {
        receiveEngine?.cancel()
        sendEngine?.cancel()
        receiveEngine = nil
        sendEngine = nil
        if isActive {
            isActive = false
            finished = true
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: ZmodemEvent) {
        switch event {
        case .sendToRemote(let data):
            enqueueWrite(data)

        case .fileOffered(let name, let size):
            fileName = name
            fileSize = size
            autoAcceptFile(name: name)

        case .progress(let progress):
            fileName = progress.fileName
            fileSize = progress.fileSize
            bytesTransferred = progress.bytesTransferred

        case .sessionFinished:
            isActive = false
            finished = true
            receiveEngine = nil
            sendEngine = nil
            writeToSession = nil

        case .error(let message):
            errorMessage = message
            isActive = false
            receiveEngine = nil
            sendEngine = nil
            writeToSession = nil
        }
    }

    // MARK: - Auto-save to Download Directory

    private func autoAcceptFile(name: String) {
        let downloadDir = resolvedDownloadDirectory()
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let fileURL = downloadDir.appendingPathComponent(name)
        // Overwrite existing file without asking
        receiveEngine?.acceptFile(saveTo: fileURL)
    }

    private func resolvedDownloadDirectory() -> URL {
        let storedPath = AppPreferences.shared.snapshot.downloadDirectoryPath
        return AppSettings.resolvedDownloadDirectoryURL(from: storedPath)
    }

    // MARK: - Serial Write Queue

    private func enqueueWrite(_ data: Data) {
        pendingWrites.append(data)
        drainWriteQueue()
    }

    private func drainWriteQueue() {
        guard !isWriting, !pendingWrites.isEmpty, let writer = writeToSession else { return }
        isWriting = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingWrites.isEmpty {
                let data = self.pendingWrites.removeFirst()
                try? await writer(data)
            }
            self.isWriting = false
        }
    }

    // MARK: - File Dialogs

    private func presentOpenPanel(completion: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = tr("ZMODEM Upload")
        panel.prompt = tr("Upload")

        panel.begin { response in
            DispatchQueue.main.async {
                if response == .OK {
                    completion(panel.urls)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func resetState() {
        receiveEngine = nil
        sendEngine = nil
        writeToSession = nil
        pendingWrites.removeAll()
        isWriting = false
        finished = false
        errorMessage = nil
        fileName = ""
        fileSize = nil
        bytesTransferred = 0
    }
}
