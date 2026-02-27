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
    case skipped = "Skipped"
}

enum TransferConflictStrategy: String, CaseIterable, Identifiable, Sendable {
    case overwrite
    case skip
    case rename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite:
            return "Overwrite"
        case .skip:
            return "Skip"
        case .rename:
            return "Rename"
        }
    }
}

struct TransferItem: Identifiable, Sendable {
    let id: UUID
    var direction: TransferDirection
    var name: String
    var sourcePath: String
    var destinationPath: String
    var status: TransferStatus
    var bytesTransferred: Int64
    var totalBytes: Int64?
    var message: String?

    init(
        id: UUID = UUID(),
        direction: TransferDirection,
        name: String,
        sourcePath: String,
        destinationPath: String,
        status: TransferStatus = .queued,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.message = message
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesTransferred) / Double(totalBytes), 0), 1)
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
    @Published var conflictStrategy: TransferConflictStrategy = .overwrite
    @Published private(set) var localEntries: [LocalFileEntry] = []
    @Published private(set) var remoteEntries: [RemoteFileEntry] = []
    @Published private(set) var transferQueue: [TransferItem] = []

    private let sftpClient: SFTPClientProtocol
    private let transferCenter: TransferCenter

    init(
        sftpClient: SFTPClientProtocol = MockSFTPClient(),
        localDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        remoteDirectoryPath: String = "/",
        maxConcurrentTransfers: Int = 2
    ) {
        self.sftpClient = sftpClient
        self.localDirectoryURL = localDirectoryURL
        self.remoteDirectoryPath = remoteDirectoryPath
        self.transferCenter = TransferCenter(maxConcurrentTransfers: maxConcurrentTransfers)

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
        enqueueUpload(localFileURLs: [localEntry.url], toRemoteDirectory: remoteDirectoryPath)
    }

    func enqueueUpload(localFileURLs: [URL], toRemoteDirectory destinationDirectory: String? = nil) {
        let baseDirectory = destinationDirectory.map(normalizeRemoteDirectoryPath) ?? remoteDirectoryPath
        for url in localFileURLs {
            enqueueUploadRecursively(localURL: url, remoteBaseDirectory: baseDirectory)
        }
    }

    func enqueueDownload(remoteEntry: RemoteFileEntry) {
        guard !remoteEntry.isDirectory else { return }

        let destinationURL = localDirectoryURL.appendingPathComponent(remoteEntry.name)
        let item = TransferItem(
            direction: .download,
            name: remoteEntry.name,
            sourcePath: remoteEntry.path,
            destinationPath: destinationURL.path,
            totalBytes: remoteEntry.size
        )
        transferQueue.append(item)
        Task {
            await executeTransfer(itemID: item.id)
        }
    }

    func deleteRemoteEntries(paths: [String]) {
        let normalizedPaths = paths
            .map(normalizeRemoteDirectoryPath)
            .filter { $0 != "/" }
        guard !normalizedPaths.isEmpty else { return }

        Task {
            for path in normalizedPaths {
                do {
                    try await sftpClient.remove(path: path)
                } catch {
                    continue
                }
            }
            await refreshRemoteEntries()
        }
    }

    func moveRemoteEntries(paths: [String], toDirectory destinationDirectory: String) {
        let destination = normalizeRemoteDirectoryPath(destinationDirectory)
        let normalizedSources = paths
            .map(normalizeRemoteDirectoryPath)
            .filter { $0 != "/" }
        guard !normalizedSources.isEmpty else { return }

        Task {
            for source in normalizedSources {
                let sourceName = URL(fileURLWithPath: source).lastPathComponent
                let targetPath = normalizedRemotePath(base: destination, child: sourceName)
                guard targetPath != source else { continue }
                do {
                    try await sftpClient.move(from: source, to: targetPath)
                } catch {
                    continue
                }
            }
            await refreshRemoteEntries()
        }
    }

    func retryTransfer(itemID: UUID) {
        guard let index = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        guard transferQueue[index].status == .failed || transferQueue[index].status == .skipped else { return }
        transferQueue[index].status = .queued
        transferQueue[index].message = nil
        transferQueue[index].bytesTransferred = 0
        Task {
            await executeTransfer(itemID: itemID)
        }
    }

    func retryFailedTransfers() {
        let failedIDs = transferQueue
            .filter { $0.status == .failed || $0.status == .skipped }
            .map(\.id)
        for id in failedIDs {
            retryTransfer(itemID: id)
        }
    }

    private func executeTransfer(itemID: UUID) async {
        await transferCenter.acquireSlot()
        defer {
            Task {
                await transferCenter.releaseSlot()
            }
        }

        guard let idx = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        var item = transferQueue[idx]

        let conflictOutcome = await resolveConflictOutcome(for: item)
        switch conflictOutcome {
        case .skip(let reason):
            transferQueue[idx].status = .skipped
            transferQueue[idx].message = reason
            return
        case .proceed(let destinationPath):
            transferQueue[idx].destinationPath = destinationPath
            item.destinationPath = destinationPath
            transferQueue[idx].status = .running
        }

        do {
            switch item.direction {
            case .upload:
                let sourceURL = URL(fileURLWithPath: item.sourcePath)
                try await sftpClient.upload(
                    fileURL: sourceURL,
                    to: item.destinationPath,
                    progress: { [weak self] snapshot in
                        Task { @MainActor in
                            self?.updateTransferProgress(itemID: itemID, snapshot: snapshot)
                        }
                    }
                )

            case .download:
                let data = try await sftpClient.download(
                    path: item.sourcePath,
                    progress: { [weak self] snapshot in
                        Task { @MainActor in
                            self?.updateTransferProgress(itemID: itemID, snapshot: snapshot)
                        }
                    }
                )
                let destinationURL = URL(fileURLWithPath: item.destinationPath)
                try data.write(to: destinationURL)
            }

            if let doneIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                transferQueue[doneIdx].status = .success
                if let total = transferQueue[doneIdx].totalBytes {
                    transferQueue[doneIdx].bytesTransferred = total
                }
                transferQueue[doneIdx].message = "Completed"
            }
        } catch {
            if let failedIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                transferQueue[failedIdx].status = .failed
                transferQueue[failedIdx].message = error.localizedDescription
            }
        }

        refreshLocalEntries()
        await refreshRemoteEntries()
    }

    var overallTransferProgress: Double? {
        let trackedItems = transferQueue.filter {
            switch $0.status {
            case .queued, .running, .success:
                return true
            case .failed, .skipped:
                return false
            }
        }

        let totalBytes = trackedItems.reduce(Int64(0)) { partial, item in
            partial + (item.totalBytes ?? 0)
        }
        guard totalBytes > 0 else { return nil }

        let completedBytes = trackedItems.reduce(Int64(0)) { partial, item in
            partial + min(item.bytesTransferred, item.totalBytes ?? item.bytesTransferred)
        }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    private func enqueueUploadRecursively(localURL: URL, remoteBaseDirectory: String) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let values = try? localURL.resourceValues(forKeys: keys)
        if values?.isDirectory == true {
            let directoryBase = normalizedRemotePath(base: remoteBaseDirectory, child: localURL.lastPathComponent)
            let fm = FileManager.default
            let rootComponents = localURL.standardizedFileURL.pathComponents
            guard let enumerator = fm.enumerator(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let childURL as URL in enumerator {
                let childValues = try? childURL.resourceValues(forKeys: keys)
                guard childValues?.isDirectory != true else { continue }
                let childComponents = childURL.standardizedFileURL.pathComponents
                guard childComponents.count > rootComponents.count else { continue }
                guard Array(childComponents.prefix(rootComponents.count)) == rootComponents else { continue }
                let relativePath = childComponents
                    .dropFirst(rootComponents.count)
                    .joined(separator: "/")
                guard !relativePath.isEmpty else { continue }
                let destination = normalizedRemotePath(base: directoryBase, child: relativePath)
                enqueueUploadFile(localURL: childURL, destinationPath: destination)
            }
            return
        }

        let destination = normalizedRemotePath(base: remoteBaseDirectory, child: localURL.lastPathComponent)
        enqueueUploadFile(localURL: localURL, destinationPath: destination)
    }

    private func enqueueUploadFile(localURL: URL, destinationPath: String) {
        let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let item = TransferItem(
            direction: .upload,
            name: localURL.lastPathComponent,
            sourcePath: localURL.path,
            destinationPath: destinationPath,
            totalBytes: fileSize
        )
        transferQueue.append(item)
        Task {
            await executeTransfer(itemID: item.id)
        }
    }

    private func updateTransferProgress(itemID: UUID, snapshot: TransferProgressSnapshot) {
        guard let index = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        transferQueue[index].bytesTransferred = snapshot.bytesTransferred
        if let total = snapshot.totalBytes {
            transferQueue[index].totalBytes = total
        }
    }

    private enum TransferConflictOutcome {
        case proceed(String)
        case skip(String)
    }

    private func resolveConflictOutcome(for item: TransferItem) async -> TransferConflictOutcome {
        switch item.direction {
        case .upload:
            guard await remotePathExists(item.destinationPath) || queuedDestinationExists(item.destinationPath, excluding: item.id) else {
                return .proceed(item.destinationPath)
            }

            switch conflictStrategy {
            case .overwrite:
                return .proceed(item.destinationPath)
            case .skip:
                return .skip("Skipped: remote path already exists")
            case .rename:
                let renamed = await uniqueRemotePath(from: item.destinationPath, excluding: item.id)
                return .proceed(renamed)
            }

        case .download:
            let localExists = FileManager.default.fileExists(atPath: item.destinationPath)
            let queuedExists = queuedDestinationExists(item.destinationPath, excluding: item.id)
            guard localExists || queuedExists else {
                return .proceed(item.destinationPath)
            }

            switch conflictStrategy {
            case .overwrite:
                return .proceed(item.destinationPath)
            case .skip:
                return .skip("Skipped: local file already exists")
            case .rename:
                let renamed = uniqueLocalPath(from: item.destinationPath, excluding: item.id)
                return .proceed(renamed)
            }
        }
    }

    private func remotePathExists(_ path: String) async -> Bool {
        do {
            _ = try await sftpClient.stat(path: path)
            return true
        } catch {
            return false
        }
    }

    private func queuedDestinationExists(_ path: String, excluding itemID: UUID) -> Bool {
        transferQueue.contains { item in
            guard item.id != itemID else { return false }
            guard item.destinationPath == path else { return false }
            return item.status == .queued || item.status == .running || item.status == .success
        }
    }

    private func uniqueRemotePath(from originalPath: String, excluding itemID: UUID) async -> String {
        var index = 1
        var candidate = originalPath
        while await remotePathExists(candidate) || queuedDestinationExists(candidate, excluding: itemID) {
            candidate = pathByAppendingSuffix(originalPath, index: index)
            index += 1
        }
        return candidate
    }

    private func uniqueLocalPath(from originalPath: String, excluding itemID: UUID) -> String {
        var index = 1
        var candidate = originalPath
        while FileManager.default.fileExists(atPath: candidate) || queuedDestinationExists(candidate, excluding: itemID) {
            candidate = pathByAppendingSuffix(originalPath, index: index)
            index += 1
        }
        return candidate
    }

    private func pathByAppendingSuffix(_ path: String, index: Int) -> String {
        let fileURL = URL(fileURLWithPath: path)
        let parent = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension
        let baseName = ext.isEmpty ? fileURL.lastPathComponent : fileURL.deletingPathExtension().lastPathComponent
        let candidateName: String
        if ext.isEmpty {
            candidateName = "\(baseName) (\(index))"
        } else {
            candidateName = "\(baseName) (\(index)).\(ext)"
        }
        return parent.appendingPathComponent(candidateName).path
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
