import Foundation
import OSLog
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

enum RemoteClipboardMode: String, Sendable {
    case copy
    case cut
}

struct RemoteClipboardState: Equatable, Sendable {
    var mode: RemoteClipboardMode
    var sourcePaths: [String]
}

enum RemoteContextAction: Sendable {
    case refresh
    case delete(paths: [String])
    case rename(path: String, newName: String)
    case copy(paths: [String])
    case cut(paths: [String])
    case paste(destinationDirectory: String)
    case download(paths: [String])
    case move(paths: [String], destinationDirectory: String)
}

struct RemoteTextDocument: Sendable {
    var path: String
    var text: String
    var encoding: String
    var modifiedAt: Date?
    var isReadOnly: Bool
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
    private struct CachedRemoteDirectory {
        var entries: [RemoteFileEntry]
        var fetchedAt: Date
    }

    private struct RemoteBindingState {
        var remoteDirectoryPath: String
        var remoteDirectoryHistory: [String]
        var remoteDirectoryHistoryIndex: Int
        var remoteDirectoryCache: [String: CachedRemoteDirectory]
        var remoteEntries: [RemoteFileEntry]
        var remoteLoadErrorMessage: String?
    }

    @Published var localDirectoryURL: URL
    @Published var remoteDirectoryPath: String
    @Published var isTerminalDirectorySyncEnabled: Bool = false
    @Published var conflictStrategy: TransferConflictStrategy = .overwrite
    @Published private(set) var canNavigateRemoteBack: Bool = false
    @Published private(set) var canNavigateRemoteForward: Bool = false
    @Published private(set) var isRemoteLoading: Bool = false
    @Published private(set) var remoteClipboard: RemoteClipboardState?
    @Published private(set) var localEntries: [LocalFileEntry] = []
    @Published private(set) var remoteEntries: [RemoteFileEntry] = []
    @Published private(set) var remoteLoadErrorMessage: String?
    @Published private(set) var transferQueue: [TransferItem] = []

    private var sftpClient: SFTPClientProtocol
    private let transferCenter: TransferCenter
    private var remoteDirectoryCache: [String: CachedRemoteDirectory] = [:]
    private var remoteRefreshInFlightPaths: Set<String> = []
    private let remoteDirectoryCacheTTL: TimeInterval = 2
    private var remoteDirectoryHistory: [String] = []
    private var remoteDirectoryHistoryIndex: Int = 0
    private var activeRemoteBindingKey = "__default"
    private var remoteBindingStates: [String: RemoteBindingState] = [:]
    private let logger = Logger(subsystem: "io.lighting-tech.remora", category: "file-transfer")

    init(
        sftpClient: SFTPClientProtocol = DisconnectedSFTPClient(),
        localDirectoryURL: URL = FileTransferViewModel.defaultLocalDirectoryURL(),
        remoteDirectoryPath: String = "/",
        maxConcurrentTransfers: Int = 2
    ) {
        self.sftpClient = sftpClient
        self.localDirectoryURL = localDirectoryURL
        self.remoteDirectoryPath = Self.normalizeStaticRemoteDirectoryPath(remoteDirectoryPath)
        self.transferCenter = TransferCenter(maxConcurrentTransfers: maxConcurrentTransfers)
        self.remoteDirectoryHistory = [self.remoteDirectoryPath]
        self.remoteDirectoryHistoryIndex = 0
        updateRemoteNavigationAvailability()

        refreshLocalEntries()
        Task {
            await refreshRemoteEntries()
        }
    }

    private static func defaultLocalDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            if !fileManager.fileExists(atPath: downloads.path) {
                try? fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
            }
            if isWritableDirectory(downloads, fileManager: fileManager) {
                return downloads
            }
        }

        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        if isWritableDirectory(current, fileManager: fileManager) {
            return current
        }

        let home = fileManager.homeDirectoryForCurrentUser
        if isWritableDirectory(home, fileManager: fileManager) {
            return home
        }

        return fileManager.homeDirectoryForCurrentUser
    }

    private static func isWritableDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fileManager.isWritableFile(atPath: url.path)
    }

    private func ensureWritableLocalDirectory() -> URL {
        if Self.isWritableDirectory(localDirectoryURL) {
            return localDirectoryURL
        }
        let fallback = Self.defaultLocalDirectoryURL()
        localDirectoryURL = fallback
        refreshLocalEntries()
        return fallback
    }

    func bindSFTPClient(
        _ client: SFTPClientProtocol,
        bindingKey: String = "__default",
        initialRemoteDirectory: String? = nil
    ) {
        let normalizedBindingKey = normalizedRemoteBindingKey(bindingKey)
        remoteBindingStates[activeRemoteBindingKey] = makeCurrentRemoteBindingState()

        sftpClient = client
        activeRemoteBindingKey = normalizedBindingKey
        remoteClipboard = nil
        transferQueue.removeAll()
        remoteRefreshInFlightPaths.removeAll()
        isRemoteLoading = false

        if let saved = remoteBindingStates[normalizedBindingKey] {
            applyRemoteBindingState(saved)
            if remoteEntries.isEmpty && remoteLoadErrorMessage == nil {
                Task {
                    await refreshRemoteEntries(
                        path: remoteDirectoryPath,
                        preferCachedFirst: true,
                        deduplicateInFlight: true
                    )
                }
            }
            return
        }

        remoteEntries = []
        remoteLoadErrorMessage = nil
        remoteDirectoryCache.removeAll()
        let initialPath = normalizeRemoteDirectoryPath(initialRemoteDirectory ?? "/")
        setRemoteDirectory(path: initialPath, recordHistory: false, resetHistory: true)

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
        let path = normalizeRemoteDirectoryPath(remoteDirectoryPath)
        await refreshRemoteEntries(
            path: path,
            preferCachedFirst: false,
            deduplicateInFlight: false
        )
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
        let targetPath = parent.isEmpty ? "/" : parent
        navigateRemote(to: targetPath)
    }

    func navigateRemoteBack() {
        guard remoteDirectoryHistoryIndex > 0 else { return }
        remoteDirectoryHistoryIndex -= 1
        let targetPath = remoteDirectoryHistory[remoteDirectoryHistoryIndex]
        setRemoteDirectory(path: targetPath, recordHistory: false, resetHistory: false)
        Task {
            await refreshRemoteEntries(
                path: targetPath,
                preferCachedFirst: true,
                deduplicateInFlight: true
            )
        }
    }

    func navigateRemoteForward() {
        guard remoteDirectoryHistoryIndex + 1 < remoteDirectoryHistory.count else { return }
        remoteDirectoryHistoryIndex += 1
        let targetPath = remoteDirectoryHistory[remoteDirectoryHistoryIndex]
        setRemoteDirectory(path: targetPath, recordHistory: false, resetHistory: false)
        Task {
            await refreshRemoteEntries(
                path: targetPath,
                preferCachedFirst: true,
                deduplicateInFlight: true
            )
        }
    }

    func navigateRemote(to path: String) {
        let normalizedTargetPath = normalizeRemoteDirectoryPath(path)
        setRemoteDirectory(path: normalizedTargetPath, recordHistory: true, resetHistory: false)
        Task {
            await refreshRemoteEntries(
                path: normalizedTargetPath,
                preferCachedFirst: true,
                deduplicateInFlight: true
            )
        }
    }

    func canPaste(into destinationDirectory: String) -> Bool {
        guard let clipboard = remoteClipboard else { return false }
        let normalizedDestination = normalizeRemoteDirectoryPath(destinationDirectory)
        return !clipboard.sourcePaths.isEmpty && normalizedDestination != ""
    }

    func performContextAction(_ action: RemoteContextAction) {
        switch action {
        case .refresh:
            refreshAll()
        case .delete(let paths):
            deleteRemoteEntries(paths: paths)
        case .rename(let path, let newName):
            renameRemoteEntry(path: path, toName: newName)
        case .copy(let paths):
            copyRemoteEntries(paths: paths, mode: .copy)
        case .cut(let paths):
            copyRemoteEntries(paths: paths, mode: .cut)
        case .paste(let destinationDirectory):
            pasteRemoteEntries(into: destinationDirectory)
        case .download(let paths):
            enqueueDownload(paths: paths)
        case .move(let paths, let destinationDirectory):
            moveRemoteEntries(paths: paths, toDirectory: destinationDirectory)
        }
    }

    func openLocal(_ entry: LocalFileEntry) {
        guard entry.isDirectory else { return }
        localDirectoryURL = entry.url
        refreshLocalEntries()
    }

    func openRemote(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else { return }
        let normalizedTargetPath = normalizeRemoteDirectoryPath(entry.path)
        setRemoteDirectory(path: normalizedTargetPath, recordHistory: true, resetHistory: false)
        Task {
            await refreshRemoteEntries(
                path: normalizedTargetPath,
                preferCachedFirst: true,
                deduplicateInFlight: true
            )
        }
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

        let destinationURL = ensureWritableLocalDirectory().appendingPathComponent(remoteEntry.name)
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

    func enqueueDownload(paths: [String]) {
        let normalized = Set(paths.map(normalizeRemoteDirectoryPath))
        for entry in remoteEntries where normalized.contains(normalizeRemoteDirectoryPath(entry.path)) && !entry.isDirectory {
            enqueueDownload(remoteEntry: entry)
        }
    }

    func createRemoteFile(named name: String, in directoryPath: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard !trimmedName.contains("/") else { return }

        let parentDirectory = normalizeRemoteDirectoryPath(directoryPath ?? remoteDirectoryPath)
        let targetPath = normalizedRemotePath(base: parentDirectory, child: trimmedName)
        guard targetPath != "/" else { return }

        Task {
            do {
                try await sftpClient.upload(data: Data(), to: targetPath)
            } catch {
                return
            }
            invalidateRemoteDirectoryCache()
            await refreshRemoteEntries(path: parentDirectory, preferCachedFirst: false, deduplicateInFlight: false)
        }
    }

    func createRemoteDirectory(named name: String, in directoryPath: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard !trimmedName.contains("/") else { return }

        let parentDirectory = normalizeRemoteDirectoryPath(directoryPath ?? remoteDirectoryPath)
        let targetPath = normalizedRemotePath(base: parentDirectory, child: trimmedName)
        guard targetPath != "/" else { return }

        Task {
            do {
                try await sftpClient.mkdir(path: targetPath)
            } catch {
                return
            }
            invalidateRemoteDirectoryCache()
            await refreshRemoteEntries(path: parentDirectory, preferCachedFirst: false, deduplicateInFlight: false)
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
            invalidateRemoteDirectoryCache()
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
                let baseTargetPath = normalizedRemotePath(base: destination, child: sourceName)
                guard let targetPath = await resolveRemoteConflictPath(for: baseTargetPath) else {
                    continue
                }
                guard targetPath != source else {
                    continue
                }
                do {
                    try await sftpClient.move(from: source, to: targetPath)
                } catch {
                    continue
                }
            }
            invalidateRemoteDirectoryCache()
            await refreshRemoteEntries()
        }
    }

    func renameRemoteEntry(path: String, toName newName: String) {
        let source = normalizeRemoteDirectoryPath(path)
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard source != "/" else { return }

        let parent = URL(fileURLWithPath: source).deletingLastPathComponent().path
        let destination = normalizedRemotePath(base: parent.isEmpty ? "/" : parent, child: trimmedName)

        Task {
            do {
                try await sftpClient.rename(from: source, to: destination)
            } catch {
                return
            }
            invalidateRemoteDirectoryCache()
            await refreshRemoteEntries()
        }
    }

    func copyRemoteEntries(paths: [String], mode: RemoteClipboardMode) {
        let normalized = Array(
            Set(paths.map(normalizeRemoteDirectoryPath).filter { $0 != "/" })
        )
        guard !normalized.isEmpty else {
            remoteClipboard = nil
            return
        }
        remoteClipboard = RemoteClipboardState(mode: mode, sourcePaths: normalized)
    }

    func pasteRemoteEntries(into destinationDirectory: String) {
        guard let clipboard = remoteClipboard else { return }
        let destination = normalizeRemoteDirectoryPath(destinationDirectory)

        Task {
            for source in clipboard.sourcePaths {
                let sourceName = URL(fileURLWithPath: source).lastPathComponent
                let baseTargetPath = normalizedRemotePath(base: destination, child: sourceName)
                guard let targetPath = await resolveRemoteConflictPath(for: baseTargetPath) else {
                    continue
                }
                guard targetPath != source else { continue }

                do {
                    switch clipboard.mode {
                    case .copy:
                        try await sftpClient.copy(from: source, to: targetPath)
                    case .cut:
                        try await sftpClient.move(from: source, to: targetPath)
                    }
                } catch {
                    continue
                }
            }

            if clipboard.mode == .cut {
                await MainActor.run {
                    remoteClipboard = nil
                }
            }

            invalidateRemoteDirectoryCache()
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

    func loadTextDocument(path: String, maxBytes: Int = 2 * 1024 * 1024) async throws -> RemoteTextDocument {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        let attributes = try? await sftpClient.stat(path: normalizedPath)
        let payload = try await sftpClient.download(path: normalizedPath)
        let isReadOnly = payload.count > maxBytes

        if let utf8 = String(data: payload, encoding: .utf8) {
            return RemoteTextDocument(
                path: normalizedPath,
                text: utf8,
                encoding: "UTF-8",
                modifiedAt: attributes?.modifiedAt,
                isReadOnly: isReadOnly
            )
        }

        if let latin1 = String(data: payload, encoding: .isoLatin1) {
            return RemoteTextDocument(
                path: normalizedPath,
                text: latin1,
                encoding: "ISO-8859-1",
                modifiedAt: attributes?.modifiedAt,
                isReadOnly: isReadOnly
            )
        }

        throw SFTPClientError.unsupportedOperation("edit-binary-file")
    }

    func saveTextDocument(
        path: String,
        text: String,
        expectedModifiedAt: Date?
    ) async throws -> Date? {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        let latestAttributes = try? await sftpClient.stat(path: normalizedPath)

        if let expectedModifiedAt, let latest = latestAttributes?.modifiedAt, latest > expectedModifiedAt {
            throw SFTPClientError.unsupportedOperation("file-modified-conflict")
        }

        guard let data = text.data(using: .utf8) else {
            throw SFTPClientError.unsupportedOperation("unsupported-text-encoding")
        }

        try await sftpClient.upload(data: data, to: normalizedPath)
        invalidateRemoteDirectoryCache()
        await refreshRemoteEntries()
        let savedAttributes = try? await sftpClient.stat(path: normalizedPath)
        return savedAttributes?.modifiedAt
    }

    func loadRemoteAttributes(path: String) async throws -> RemoteFileAttributes {
        try await sftpClient.stat(path: normalizeRemoteDirectoryPath(path))
    }

    func saveRemoteAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try await sftpClient.setAttributes(path: normalizeRemoteDirectoryPath(path), attributes: attributes)
        invalidateRemoteDirectoryCache()
        await refreshRemoteEntries()
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
                let destinationDirectory = destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                try data.write(to: destinationURL)
                guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw NSError(
                        domain: "Remora.FileTransfer",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Download finished but local file is missing: \(destinationURL.path)"]
                    )
                }
            }

            if let doneIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                transferQueue[doneIdx].status = .success
                if let total = transferQueue[doneIdx].totalBytes {
                    transferQueue[doneIdx].bytesTransferred = total
                }
                if item.direction == .download {
                    let displayPath = NSString(string: transferQueue[doneIdx].destinationPath).abbreviatingWithTildeInPath
                    transferQueue[doneIdx].message = "Saved to: \(displayPath)"
                } else {
                    transferQueue[doneIdx].message = "Completed"
                }
            }
        } catch {
            if let failedIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                transferQueue[failedIdx].status = .failed
                transferQueue[failedIdx].message = error.localizedDescription
                let failedItem = transferQueue[failedIdx]
                logger.error(
                    "transfer failed direction=\(failedItem.direction.rawValue, privacy: .public) source=\(failedItem.sourcePath, privacy: .public) destination=\(failedItem.destinationPath, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        refreshLocalEntries()
        if item.direction == .upload {
            invalidateRemoteDirectoryCache()
            await refreshRemoteEntries()
        }
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

    private func resolveRemoteConflictPath(for destinationPath: String) async -> String? {
        let normalized = normalizeRemoteDirectoryPath(destinationPath)
        guard await remotePathExists(normalized) else { return normalized }

        switch conflictStrategy {
        case .overwrite:
            return normalized
        case .skip:
            return nil
        case .rename:
            var index = 1
            var candidate = normalized
            while await remotePathExists(candidate) {
                candidate = pathByAppendingSuffix(normalized, index: index)
                index += 1
            }
            return candidate
        }
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
        let trimmedChild = child.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChild.isEmpty else { return normalizeRemoteDirectoryPath(base) }
        if trimmedChild.hasPrefix("/") {
            return normalizeRemoteDirectoryPath(trimmedChild)
        }
        if base == "/" {
            return normalizeRemoteDirectoryPath("/\(trimmedChild)")
        }
        return normalizeRemoteDirectoryPath("\(base)/\(trimmedChild)")
    }

    private func normalizeRemoteDirectoryPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        let collapsed = prefixed.replacingOccurrences(of: "//", with: "/")
        return collapsed.isEmpty ? "/" : collapsed
    }

    private static func normalizeStaticRemoteDirectoryPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        let collapsed = prefixed.replacingOccurrences(of: "//", with: "/")
        return collapsed.isEmpty ? "/" : collapsed
    }

    private func refreshRemoteEntries(
        path rawPath: String,
        preferCachedFirst: Bool,
        deduplicateInFlight: Bool
    ) async {
        let path = normalizeRemoteDirectoryPath(rawPath)

        if preferCachedFirst, let cached = remoteDirectoryCache[path] {
            if remoteDirectoryPath == path {
                remoteEntries = cached.entries
                remoteLoadErrorMessage = nil
            }

            let cacheAge = Date().timeIntervalSince(cached.fetchedAt)
            if cacheAge <= remoteDirectoryCacheTTL {
                updateRemoteLoadingState()
                return
            }
        }

        if deduplicateInFlight, remoteRefreshInFlightPaths.contains(path) {
            updateRemoteLoadingState()
            return
        }

        remoteRefreshInFlightPaths.insert(path)
        updateRemoteLoadingState()
        defer {
            remoteRefreshInFlightPaths.remove(path)
            updateRemoteLoadingState()
        }

        do {
            let entries = try await sftpClient.list(path: path)
            let sorted = sortRemoteEntries(entries)
            remoteDirectoryCache[path] = CachedRemoteDirectory(entries: sorted, fetchedAt: Date())
            if remoteDirectoryPath == path {
                remoteEntries = sorted
                remoteLoadErrorMessage = nil
            }
        } catch {
            if let cached = remoteDirectoryCache[path], !cached.entries.isEmpty {
                if remoteDirectoryPath == path {
                    remoteEntries = cached.entries
                    remoteLoadErrorMessage = nil
                }
                return
            }

            if remoteDirectoryPath == path {
                remoteEntries = []
                remoteLoadErrorMessage = error.localizedDescription
            }
        }
    }

    private func sortRemoteEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func invalidateRemoteDirectoryCache() {
        remoteDirectoryCache.removeAll()
        remoteRefreshInFlightPaths.removeAll()
        updateRemoteLoadingState()
    }

    private func setRemoteDirectory(path: String, recordHistory: Bool, resetHistory: Bool) {
        let normalized = normalizeRemoteDirectoryPath(path)
        remoteDirectoryPath = normalized

        if resetHistory {
            remoteDirectoryHistory = [normalized]
            remoteDirectoryHistoryIndex = 0
            updateRemoteNavigationAvailability()
            updateRemoteLoadingState()
            return
        }

        guard recordHistory else {
            updateRemoteNavigationAvailability()
            updateRemoteLoadingState()
            return
        }

        if remoteDirectoryHistory.isEmpty {
            remoteDirectoryHistory = [normalized]
            remoteDirectoryHistoryIndex = 0
            updateRemoteNavigationAvailability()
            updateRemoteLoadingState()
            return
        }

        if remoteDirectoryHistory[remoteDirectoryHistoryIndex] == normalized {
            updateRemoteNavigationAvailability()
            updateRemoteLoadingState()
            return
        }

        if remoteDirectoryHistoryIndex + 1 < remoteDirectoryHistory.count {
            remoteDirectoryHistory.removeSubrange((remoteDirectoryHistoryIndex + 1) ..< remoteDirectoryHistory.count)
        }

        remoteDirectoryHistory.append(normalized)
        remoteDirectoryHistoryIndex = remoteDirectoryHistory.count - 1
        updateRemoteNavigationAvailability()
        updateRemoteLoadingState()
    }

    private func updateRemoteNavigationAvailability() {
        canNavigateRemoteBack = remoteDirectoryHistoryIndex > 0
        canNavigateRemoteForward = remoteDirectoryHistoryIndex + 1 < remoteDirectoryHistory.count
    }

    private func updateRemoteLoadingState() {
        let currentPath = normalizeRemoteDirectoryPath(remoteDirectoryPath)
        isRemoteLoading = remoteRefreshInFlightPaths.contains(currentPath)
    }

    private func makeCurrentRemoteBindingState() -> RemoteBindingState {
        RemoteBindingState(
            remoteDirectoryPath: remoteDirectoryPath,
            remoteDirectoryHistory: remoteDirectoryHistory,
            remoteDirectoryHistoryIndex: remoteDirectoryHistoryIndex,
            remoteDirectoryCache: remoteDirectoryCache,
            remoteEntries: remoteEntries,
            remoteLoadErrorMessage: remoteLoadErrorMessage
        )
    }

    private func applyRemoteBindingState(_ state: RemoteBindingState) {
        remoteDirectoryPath = normalizeRemoteDirectoryPath(state.remoteDirectoryPath)
        remoteDirectoryHistory = state.remoteDirectoryHistory.isEmpty
            ? [remoteDirectoryPath]
            : state.remoteDirectoryHistory.map { normalizeRemoteDirectoryPath($0) }
        remoteDirectoryHistoryIndex = min(
            max(state.remoteDirectoryHistoryIndex, 0),
            max(remoteDirectoryHistory.count - 1, 0)
        )
        remoteDirectoryCache = state.remoteDirectoryCache
        remoteEntries = state.remoteEntries
        remoteLoadErrorMessage = state.remoteLoadErrorMessage
        updateRemoteNavigationAvailability()
        updateRemoteLoadingState()
    }

    private func normalizedRemoteBindingKey(_ rawKey: String) -> String {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "__default" : trimmed
    }
}
