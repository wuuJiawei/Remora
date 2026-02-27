import Foundation
import RemoraCore

enum TransferDirection: String, Sendable {
    case upload = "Upload"
    case download = "Download"
}

enum TransferStatus: String, Sendable {
    case queued = "Queued"
    case running = "Running"
    case success = "Success"
    case failed = "Failed"
}

struct TransferItem: Identifiable, Sendable {
    let id: UUID
    var direction: TransferDirection
    var name: String
    var sourcePath: String
    var destinationPath: String
    var status: TransferStatus
    var message: String?

    init(
        id: UUID = UUID(),
        direction: TransferDirection,
        name: String,
        sourcePath: String,
        destinationPath: String,
        status: TransferStatus = .queued,
        message: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
        self.message = message
    }
}

struct LocalFileEntry: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64

    init(url: URL, name: String, isDirectory: Bool, size: Int64) {
        self.id = UUID()
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

@MainActor
final class FileTransferViewModel: ObservableObject {
    @Published var localDirectoryURL: URL
    @Published var remoteDirectoryPath: String
    @Published private(set) var localEntries: [LocalFileEntry] = []
    @Published private(set) var remoteEntries: [RemoteFileEntry] = []
    @Published private(set) var transferQueue: [TransferItem] = []

    private let sftpClient: SFTPClientProtocol
    private let maxConcurrentTransfers: Int
    private var runningTransferIDs: Set<UUID> = []

    init(
        sftpClient: SFTPClientProtocol = MockSFTPClient(),
        localDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        remoteDirectoryPath: String = "/",
        maxConcurrentTransfers: Int = 2
    ) {
        self.sftpClient = sftpClient
        self.localDirectoryURL = localDirectoryURL
        self.remoteDirectoryPath = remoteDirectoryPath
        self.maxConcurrentTransfers = max(1, maxConcurrentTransfers)

        refreshLocalEntries()
        Task {
            await refreshRemoteEntries()
        }
    }

    func refreshAll() {
        refreshLocalEntries()
        Task {
            await refreshRemoteEntries()
        }
    }

    func refreshLocalEntries() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]

        do {
            let urls = try fm.contentsOfDirectory(
                at: localDirectoryURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )

            let mapped: [LocalFileEntry] = urls.compactMap { url in
                let resource = try? url.resourceValues(forKeys: Set(keys))
                return LocalFileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: resource?.isDirectory ?? false,
                    size: Int64(resource?.fileSize ?? 0)
                )
            }

            localEntries = mapped.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            localEntries = []
        }
    }

    func refreshRemoteEntries() async {
        do {
            let entries = try await sftpClient.list(path: remoteDirectoryPath)
            remoteEntries = entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            remoteEntries = []
        }
    }

    func goUpLocalDirectory() {
        let parent = localDirectoryURL.deletingLastPathComponent()
        guard parent.path != localDirectoryURL.path else { return }
        localDirectoryURL = parent
        refreshLocalEntries()
    }

    func goUpRemoteDirectory() {
        guard remoteDirectoryPath != "/" else { return }
        let parent = URL(fileURLWithPath: remoteDirectoryPath).deletingLastPathComponent().path
        remoteDirectoryPath = parent.isEmpty ? "/" : parent
        Task { await refreshRemoteEntries() }
    }

    func navigateRemote(to path: String) {
        remoteDirectoryPath = normalizeRemoteDirectoryPath(path)
        Task { await refreshRemoteEntries() }
    }

    func openLocal(_ entry: LocalFileEntry) {
        guard entry.isDirectory else { return }
        localDirectoryURL = entry.url
        refreshLocalEntries()
    }

    func openRemote(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else { return }
        remoteDirectoryPath = normalizedRemotePath(base: remoteDirectoryPath, child: entry.name)
        Task { await refreshRemoteEntries() }
    }

    func enqueueUpload(localEntry: LocalFileEntry) {
        guard !localEntry.isDirectory else { return }

        let destination = normalizedRemotePath(base: remoteDirectoryPath, child: localEntry.name)
        let item = TransferItem(
            direction: .upload,
            name: localEntry.name,
            sourcePath: localEntry.url.path,
            destinationPath: destination
        )
        transferQueue.append(item)
        processQueueIfNeeded()
    }

    func enqueueDownload(remoteEntry: RemoteFileEntry) {
        guard !remoteEntry.isDirectory else { return }

        let destinationURL = localDirectoryURL.appendingPathComponent(remoteEntry.name)
        let item = TransferItem(
            direction: .download,
            name: remoteEntry.name,
            sourcePath: remoteEntry.path,
            destinationPath: destinationURL.path
        )
        transferQueue.append(item)
        processQueueIfNeeded()
    }

    private func processQueueIfNeeded() {
        while runningTransferIDs.count < maxConcurrentTransfers,
              let nextIndex = transferQueue.firstIndex(where: { $0.status == .queued })
        {
            let itemID = transferQueue[nextIndex].id
            transferQueue[nextIndex].status = .running
            runningTransferIDs.insert(itemID)

            Task {
                await executeTransfer(itemID: itemID)
            }
        }
    }

    private func executeTransfer(itemID: UUID) async {
        guard let idx = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        let item = transferQueue[idx]

        do {
            switch item.direction {
            case .upload:
                let sourceURL = URL(fileURLWithPath: item.sourcePath)
                let data = try Data(contentsOf: sourceURL)
                try await sftpClient.upload(data: data, to: item.destinationPath)

            case .download:
                let data = try await sftpClient.download(path: item.sourcePath)
                let destinationURL = URL(fileURLWithPath: item.destinationPath)
                try data.write(to: destinationURL)
            }

            if let doneIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                transferQueue[doneIdx].status = .success
                transferQueue[doneIdx].message = "Completed"
            }
        } catch {
            if let failedIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                transferQueue[failedIdx].status = .failed
                transferQueue[failedIdx].message = error.localizedDescription
            }
        }

        runningTransferIDs.remove(itemID)
        refreshLocalEntries()
        await refreshRemoteEntries()
        processQueueIfNeeded()
    }

    private func normalizedRemotePath(base: String, child: String) -> String {
        if base == "/" {
            return "/\(child)"
        }
        return "\(base)/\(child)".replacingOccurrences(of: "//", with: "/")
    }

    private func normalizeRemoteDirectoryPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        let collapsed = prefixed.replacingOccurrences(of: "//", with: "/")
        return collapsed.isEmpty ? "/" : collapsed
    }
}
