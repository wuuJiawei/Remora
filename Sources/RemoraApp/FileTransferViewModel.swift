import Combine
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
    case stopped = "Stopped"

    var isTerminal: Bool {
        switch self {
        case .success, .failed, .skipped, .stopped:
            return true
        case .queued, .running:
            return false
        }
    }
}

enum TransferConflictStrategy: String, CaseIterable, Identifiable, Sendable {
    case overwrite
    case skip
    case rename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite:
            return tr("Overwrite")
        case .skip:
            return tr("Skip")
        case .rename:
            return tr("Rename")
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

struct RemoteTextDocumentLoadOptions: Sendable {
    var knownSize: Int64?
    var knownModifiedAt: Date?

    init(knownSize: Int64? = nil, knownModifiedAt: Date? = nil) {
        self.knownSize = knownSize
        self.knownModifiedAt = knownModifiedAt
    }
}

enum RemoteTextDocumentError: Error, Equatable, Sendable {
    case fileTooLarge(actualBytes: Int64, maxBytes: Int64)
}

enum RemoteSearchScope: String, CaseIterable, Identifiable, Sendable {
    case currentDirectory
    case currentDirectoryRecursive
    case entireServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentDirectory:
            return tr("Current Directory")
        case .currentDirectoryRecursive:
            return tr("Subfolders")
        case .entireServer:
            return tr("Entire Server")
        }
    }
}

enum RemoteSearchActivityKind: Equatable, Sendable {
    case directory
    case file
}

struct RemoteSearchActivity: Identifiable, Equatable, Sendable {
    var path: String
    var kind: RemoteSearchActivityKind

    var id: String { path }
}

struct RemoteSearchResult: Identifiable, Equatable, Sendable {
    var path: String
    var name: String
    var parentPath: String
    var isDirectory: Bool

    var id: String { path }
}

struct RemoteSearchStatus: Equatable, Sendable {
    var query: String = ""
    var scope: RemoteSearchScope = .currentDirectory
    var rootPath: String = "/"
    var isRunning: Bool = false
    var visitedCount: Int = 0
    var matchedCount: Int = 0
    var statusText: String?
    var errorMessage: String?
    var activity: [RemoteSearchActivity] = []
    var isResultTruncated: Bool = false

    var hasActiveQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct TransferItem: Identifiable, Sendable {
    let id: UUID
    var batchID: Int
    var direction: TransferDirection
    var name: String
    var sourcePath: String
    var destinationPath: String
    var status: TransferStatus
    var bytesTransferred: Int64
    var totalBytes: Int64?
    var speedBytesPerSecond: Int64?
    var message: String?
    var lastProgressSampleBytes: Int64?
    var lastProgressSampleDate: Date?

    init(
        id: UUID = UUID(),
        batchID: Int = 0,
        direction: TransferDirection,
        name: String,
        sourcePath: String,
        destinationPath: String,
        status: TransferStatus = .queued,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64? = nil,
        speedBytesPerSecond: Int64? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.direction = direction
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.message = message
        self.lastProgressSampleBytes = nil
        self.lastProgressSampleDate = nil
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesTransferred) / Double(totalBytes), 0), 1)
    }
}

private struct DirectoryDownloadPlanNode: Sendable {
    var entry: RemoteFileEntry
    var children: [DirectoryDownloadPlanNode]
    var totalFileBytes: Int64
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
    static let maxInlineEditableTextDocumentBytes = 2 * 1024 * 1024
    static let defaultRemoteLogTailLineCount = 399
    static let maxRemoteLogTailLineCount = 5000
    static let maxRemoteSearchResults = 500

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
    @Published private(set) var archiveOperationProgress: Double?
    @Published private(set) var archiveOperationStatusText: String?
    @Published private(set) var transferQueue: [TransferItem] = []
    @Published private(set) var currentTransferBatchID: Int?
    @Published private(set) var remoteSearchResults: [RemoteSearchResult] = []
    @Published private(set) var remoteSearchStatus = RemoteSearchStatus()

    private var sftpClient: SFTPClientProtocol
    private let transferCenter: TransferCenter
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var remoteSearchTask: Task<Void, Never>?
    private var remoteSearchGeneration: Int = 0
    private var nextTransferBatchSeed: Int = 0
    private var remoteDirectoryCache: [String: CachedRemoteDirectory] = [:]
    private var remoteRefreshInFlightPaths: Set<String> = []
    private let remoteDirectoryCacheTTL: TimeInterval = 2
    private var remoteDirectoryHistory: [String] = []
    private var remoteDirectoryHistoryIndex: Int = 0
    private var activeRemoteBindingKey = "__default"
    private var remoteBindingStates: [String: RemoteBindingState] = [:]
    // Increments on every bindSFTPClient call. Async remote-load tasks must match
    // the latest generation before mutating published state, preventing stale
    // results from old session bindings from overwriting the current UI.
    private var sftpBindingGeneration: Int = 0
    private var downloadDirectoryChangeCancellable: AnyCancellable?
    private let logger = Logger(subsystem: "io.lighting-tech.remora", category: "file-transfer")

    init(
        sftpClient: SFTPClientProtocol = DisconnectedSFTPClient(),
        localDirectoryURL: URL = FileTransferViewModel.configuredLocalDirectoryURL(),
        remoteDirectoryPath: String = "/",
        maxConcurrentTransfers: Int = 2
    ) {
        self.sftpClient = sftpClient
        self.localDirectoryURL = Self.resolveWritableLocalDirectory(from: localDirectoryURL)
        self.remoteDirectoryPath = Self.normalizeStaticRemoteDirectoryPath(remoteDirectoryPath)
        self.transferCenter = TransferCenter(maxConcurrentTransfers: maxConcurrentTransfers)
        self.remoteDirectoryHistory = [self.remoteDirectoryPath]
        self.remoteDirectoryHistoryIndex = 0
        updateRemoteNavigationAvailability()

        downloadDirectoryChangeCancellable = NotificationCenter.default.publisher(
            for: .remoraDownloadDirectoryDidChange
        )
        .sink { [weak self] notification in
            guard let self else { return }
            let path = (notification.object as? String)
                ?? (notification.userInfo?["path"] as? String)
            self.applyConfiguredDownloadDirectory(path)
        }

        refreshLocalEntries()
        Task {
            await refreshRemoteEntries()
        }
    }

    private static func configuredLocalDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        AppSettings.resolvedDownloadDirectoryURL(
            from: AppPreferences.shared.value(for: \.downloadDirectoryPath),
            fileManager: fileManager
        )
    }

    private static func resolveWritableLocalDirectory(
        from candidate: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let normalized = candidate.standardizedFileURL
        if AppSettings.isWritableDirectory(normalized, fileManager: fileManager) {
            return normalized
        }
        return configuredLocalDirectoryURL(fileManager: fileManager)
    }

    private func ensureWritableLocalDirectory() -> URL {
        if AppSettings.isWritableDirectory(localDirectoryURL) {
            return localDirectoryURL
        }
        let fallback = AppSettings.defaultDownloadDirectoryURL()
        localDirectoryURL = fallback
        refreshLocalEntries()
        return fallback
    }

    private func applyConfiguredDownloadDirectory(_ path: String?) {
        let rawPath = path ?? AppPreferences.shared.value(for: \.downloadDirectoryPath)
        let resolved = AppSettings.resolvedDownloadDirectoryURL(from: rawPath)
        guard localDirectoryURL.standardizedFileURL != resolved.standardizedFileURL else { return }
        localDirectoryURL = resolved
        refreshLocalEntries()
    }

    func bindSFTPClient(
        _ client: SFTPClientProtocol,
        bindingKey: String = "__default",
        initialRemoteDirectory: String? = nil
    ) {
        let normalizedBindingKey = normalizedRemoteBindingKey(bindingKey)
        sftpBindingGeneration += 1
        let bindingGeneration = sftpBindingGeneration
        remoteBindingStates[activeRemoteBindingKey] = makeCurrentRemoteBindingState()

        sftpClient = client
        activeRemoteBindingKey = normalizedBindingKey
        clearRemoteSearch()
        remoteClipboard = nil
        cancelTrackedTransfers(clearQueue: true)
        currentTransferBatchID = nil
        nextTransferBatchSeed = 0
        remoteRefreshInFlightPaths.removeAll()
        isRemoteLoading = false

        if let saved = remoteBindingStates[normalizedBindingKey] {
            applyRemoteBindingState(saved)
            if remoteEntries.isEmpty && remoteLoadErrorMessage == nil {
                Task {
                    await refreshRemoteEntries(
                        path: remoteDirectoryPath,
                        preferCachedFirst: true,
                        deduplicateInFlight: true,
                        bindingGeneration: bindingGeneration
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
            await refreshRemoteEntries(bindingGeneration: bindingGeneration)
        }
    }

    func refreshAll() {
        let bindingGeneration = sftpBindingGeneration
        refreshLocalEntries()
        Task {
            await refreshRemoteEntries(bindingGeneration: bindingGeneration)
        }
    }

    func performRemoteSearch(
        query rawQuery: String,
        scope: RemoteSearchScope,
        rootPath: String? = nil
    ) {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            clearRemoteSearch()
            return
        }

        cancelRemoteSearch(resetState: false)
        let normalizedRootPath = scope == .entireServer
            ? "/"
            : normalizeRemoteDirectoryPath(rootPath ?? remoteDirectoryPath)

        remoteSearchStatus = RemoteSearchStatus(
            query: trimmedQuery,
            scope: scope,
            rootPath: normalizedRootPath,
            isRunning: scope != .currentDirectory,
            visitedCount: 0,
            matchedCount: 0,
            statusText: initialRemoteSearchStatusText(scope: scope, rootPath: normalizedRootPath),
            errorMessage: nil,
            activity: [],
            isResultTruncated: false
        )
        remoteSearchResults = []

        switch scope {
        case .currentDirectory:
            applyCurrentDirectorySearch(query: trimmedQuery, rootPath: normalizedRootPath)

        case .currentDirectoryRecursive, .entireServer:
            remoteSearchGeneration += 1
            let generation = remoteSearchGeneration
            remoteSearchTask = Task { [weak self] in
                guard let self else { return }
                await self.runRemoteSearch(
                    query: trimmedQuery,
                    scope: scope,
                    rootPath: normalizedRootPath,
                    generation: generation
                )
            }
        }
    }

    func cancelRemoteSearch(resetState: Bool = false) {
        remoteSearchGeneration += 1
        remoteSearchTask?.cancel()
        remoteSearchTask = nil

        guard remoteSearchStatus.hasActiveQuery else {
            if resetState {
                remoteSearchResults = []
                remoteSearchStatus = RemoteSearchStatus()
            }
            return
        }

        remoteSearchStatus.isRunning = false
        remoteSearchStatus.activity = []
        remoteSearchStatus.errorMessage = nil
        remoteSearchStatus.statusText = completedRemoteSearchStatusText(
            visitedCount: remoteSearchStatus.visitedCount,
            matchedCount: remoteSearchStatus.matchedCount
        )

        if resetState {
            remoteSearchResults = []
            remoteSearchStatus = RemoteSearchStatus()
        }
    }

    func clearRemoteSearch() {
        cancelRemoteSearch(resetState: true)
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

    func refreshRemoteEntries(bindingGeneration: Int? = nil) async {
        let path = normalizeRemoteDirectoryPath(remoteDirectoryPath)
        await refreshRemoteEntries(
            path: path,
            preferCachedFirst: false,
            deduplicateInFlight: false,
            bindingGeneration: bindingGeneration ?? sftpBindingGeneration
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
        let destinationURL = ensureWritableLocalDirectory().appendingPathComponent(remoteEntry.name)
        let item = TransferItem(
            batchID: prepareBatchIDForNewTransfer(),
            direction: .download,
            name: remoteEntry.name,
            sourcePath: remoteEntry.path,
            destinationPath: destinationURL.path,
            totalBytes: remoteEntry.isDirectory ? nil : remoteEntry.size
        )
        transferQueue.append(item)
        startTransferTask(for: item.id)
    }

    func enqueueDownload(paths: [String]) {
        let normalized = Set(paths.map(normalizeRemoteDirectoryPath))
        for entry in remoteEntries where normalized.contains(normalizeRemoteDirectoryPath(entry.path)) {
            enqueueDownload(remoteEntry: entry)
        }
    }

    func enqueueDownload(path: String) async throws {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        let attributes = try await loadRemoteAttributes(path: normalizedPath)
        let entry = RemoteFileEntry(
            name: URL(fileURLWithPath: normalizedPath).lastPathComponent,
            path: normalizedPath,
            size: attributes.size,
            permissions: attributes.permissions,
            owner: attributes.owner,
            group: attributes.group,
            isDirectory: attributes.isDirectory,
            modifiedAt: attributes.modifiedAt
        )
        enqueueDownload(remoteEntry: entry)
    }

    func compressRemoteEntries(
        paths: [String],
        archiveName: String,
        format: ArchiveFormat,
        destinationDirectory: String? = nil
    ) async throws {
        guard format.supportsCompression else {
            throw ArchiveSupportError.unsupportedCompressionFormat
        }

        let normalizedSources = Array(Set(paths.map(normalizeRemoteDirectoryPath).filter { $0 != "/" }))
        guard !normalizedSources.isEmpty else { return }

        let workspaceURL = Self.makeArchiveWorkspaceURL()
        let stagingURL = workspaceURL.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        beginArchiveProgress(status: tr("Preparing files…"), progress: 0.15)
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            clearArchiveProgress()
        }

        for source in normalizedSources {
            let topLevelURL = stagingURL.appendingPathComponent(URL(fileURLWithPath: source).lastPathComponent)
            try await materializeRemoteItem(at: source, to: topLevelURL)
        }

        let finalArchiveName = archiveName.hasSuffix(format.fileExtension) ? archiveName : archiveName + format.fileExtension
        let archiveURL = workspaceURL.appendingPathComponent(finalArchiveName)
        updateArchiveProgress(status: tr("Compressing files…"), progress: 0.5)
        try ArchiveSupport.createArchive(from: stagingURL, destinationURL: archiveURL, format: format)

        let destination = normalizeRemoteDirectoryPath(destinationDirectory ?? remoteDirectoryPath)
        let targetPath = normalizedRemotePath(base: destination, child: finalArchiveName)
        guard let resolvedTargetPath = await resolveRemoteConflictPath(for: targetPath) else { return }

        updateArchiveProgress(status: tr("Uploading archive…"), progress: 0.8)
        try await sftpClient.upload(fileURL: archiveURL, to: resolvedTargetPath, progress: nil)
        invalidateRemoteDirectoryCache()
        await refreshRemoteEntries(path: destination, preferCachedFirst: false, deduplicateInFlight: false)
        updateArchiveProgress(status: tr("Finalizing…"), progress: 1.0)
    }

    func extractRemoteArchive(path: String, into destinationDirectory: String? = nil) async throws {
        let normalizedArchivePath = normalizeRemoteDirectoryPath(path)
        guard ArchiveFormat.extractFormat(for: normalizedArchivePath) != nil else {
            throw ArchiveSupportError.unsupportedExtractionFormat
        }

        let workspaceURL = Self.makeArchiveWorkspaceURL()
        let archiveURL = workspaceURL.appendingPathComponent(URL(fileURLWithPath: normalizedArchivePath).lastPathComponent)
        let extractedURL = workspaceURL.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        beginArchiveProgress(status: tr("Preparing files…"), progress: 0.15)
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            clearArchiveProgress()
        }

        try await sftpClient.download(path: normalizedArchivePath, to: archiveURL, progress: nil)
        updateArchiveProgress(status: tr("Extracting archive…"), progress: 0.45)
        try ArchiveSupport.extractArchive(at: archiveURL, to: extractedURL)

        let destination = normalizeRemoteDirectoryPath(destinationDirectory ?? remoteDirectoryPath)
        try await ensureRemoteDirectoryExists(destination)
        let extractedItems = try FileManager.default.contentsOfDirectory(at: extractedURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        updateArchiveProgress(status: tr("Uploading extracted files…"), progress: 0.8)
        for item in extractedItems {
            try await uploadExtractedItem(item, toRemoteBasePath: destination)
        }

        invalidateRemoteDirectoryCache()
        await refreshRemoteEntries(path: destination, preferCachedFirst: false, deduplicateInFlight: false)
        updateArchiveProgress(status: tr("Finalizing…"), progress: 1.0)
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
        guard transferQueue[index].status == .failed || transferQueue[index].status == .skipped || transferQueue[index].status == .stopped else { return }
        transferQueue[index].batchID = prepareBatchIDForNewTransfer()
        transferQueue[index].status = .queued
        transferQueue[index].message = nil
        transferQueue[index].bytesTransferred = 0
        transferQueue[index].speedBytesPerSecond = nil
        transferQueue[index].lastProgressSampleBytes = nil
        transferQueue[index].lastProgressSampleDate = nil
        startTransferTask(for: itemID)
    }

    func retryFailedTransfers() {
        let failedIDs = transferQueue
            .filter { $0.status == .failed || $0.status == .skipped || $0.status == .stopped }
            .map(\.id)
        let retryBatchID = prepareBatchIDForNewTransfer()
        for id in failedIDs {
            if let index = transferQueue.firstIndex(where: { $0.id == id }) {
                transferQueue[index].batchID = retryBatchID
            }
            retryTransfer(itemID: id)
        }
    }

    func stopTransfer(itemID: UUID) {
        guard let index = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        let status = transferQueue[index].status
        guard status == .queued || status == .running else { return }
        transferTasks[itemID]?.cancel()
        markTransferStopped(itemID: itemID)
    }

    func stopAllTransfers() {
        let stoppableIDs = transferQueue
            .filter { $0.status == .queued || $0.status == .running }
            .map(\.id)
        for id in stoppableIDs {
            stopTransfer(itemID: id)
        }
    }

    func loadTextDocument(
        path: String,
        options: RemoteTextDocumentLoadOptions = RemoteTextDocumentLoadOptions(),
        maxBytes: Int = FileTransferViewModel.maxInlineEditableTextDocumentBytes
    ) async throws -> RemoteTextDocument {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        let maxAllowedBytes = Int64(maxBytes)
        let knownSize = options.knownSize

        if let knownSize, knownSize > maxAllowedBytes {
            throw RemoteTextDocumentError.fileTooLarge(
                actualBytes: knownSize,
                maxBytes: maxAllowedBytes
            )
        }

        let modifiedAt: Date?
        if knownSize == nil || options.knownModifiedAt == nil {
            let attributes = try await sftpClient.stat(path: normalizedPath)
            if attributes.size > maxAllowedBytes {
                throw RemoteTextDocumentError.fileTooLarge(
                    actualBytes: attributes.size,
                    maxBytes: maxAllowedBytes
                )
            }
            modifiedAt = options.knownModifiedAt ?? attributes.modifiedAt
        } else {
            modifiedAt = options.knownModifiedAt
        }

        let tempURL = Self.makeTemporaryTextDocumentURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await sftpClient.download(path: normalizedPath, to: tempURL, progress: nil)

        let payload = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
        if payload.count > maxBytes {
            throw RemoteTextDocumentError.fileTooLarge(
                actualBytes: Int64(payload.count),
                maxBytes: maxAllowedBytes
            )
        }

        return try await Self.decodeTextDocument(
            path: normalizedPath,
            payload: payload,
            modifiedAt: modifiedAt
        )
    }

    func loadRemoteLogTail(
        path: String,
        lineCount: Int = FileTransferViewModel.defaultRemoteLogTailLineCount
    ) async throws -> String {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        let clampedLineCount = min(max(lineCount, 1), Self.maxRemoteLogTailLineCount)
        let command = "LC_ALL=C tail -n \(clampedLineCount) \(Self.quoteShellArgument(normalizedPath))"
        return try await sftpClient.executeRemoteShellCommand(command, timeout: 15)
    }

    func streamRemoteLogTail(
        path: String,
        lineCount: Int = FileTransferViewModel.defaultRemoteLogTailLineCount
    ) async throws -> AsyncThrowingStream<String, Error> {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        let clampedLineCount = min(max(lineCount, 1), Self.maxRemoteLogTailLineCount)
        let command = "LC_ALL=C tail -n \(clampedLineCount) -f \(Self.quoteShellArgument(normalizedPath))"
        return try await sftpClient.streamRemoteShellCommand(command)
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

    func saveRemoteAttributes(path: String, attributes: RemoteFileAttributes, recursively: Bool = false) async throws {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        if recursively {
            try await saveRemoteAttributesRecursively(path: normalizedPath, template: attributes)
        } else {
            try await sftpClient.setAttributes(path: normalizedPath, attributes: attributes)
        }
        invalidateRemoteDirectoryCache()
        await refreshRemoteEntries()
    }

    private func saveRemoteAttributesRecursively(path: String, template: RemoteFileAttributes) async throws {
        let currentAttributes = try await sftpClient.stat(path: path)
        let appliedAttributes = RemoteFileAttributes(
            permissions: template.permissions,
            owner: template.owner,
            group: template.group,
            size: currentAttributes.size,
            modifiedAt: currentAttributes.modifiedAt,
            isDirectory: currentAttributes.isDirectory
        )
        try await sftpClient.setAttributes(path: path, attributes: appliedAttributes)

        guard currentAttributes.isDirectory else { return }
        let children = try await sftpClient.list(path: path)
        for child in children {
            try await saveRemoteAttributesRecursively(
                path: normalizeRemoteDirectoryPath(child.path),
                template: RemoteFileAttributes(
                    permissions: template.permissions,
                    owner: template.owner,
                    group: template.group,
                    size: child.size,
                    modifiedAt: child.modifiedAt,
                    isDirectory: child.isDirectory
                )
            )
        }
    }

    private func applyCurrentDirectorySearch(query: String, rootPath: String) {
        let sourceEntries: [RemoteFileEntry]
        if normalizeRemoteDirectoryPath(remoteDirectoryPath) == rootPath {
            sourceEntries = remoteEntries
        } else {
            sourceEntries = remoteDirectoryCache[rootPath]?.entries ?? []
        }

        let matches = sourceEntries
            .filter { remoteSearchEntryName($0).localizedCaseInsensitiveContains(query) }
            .map(makeRemoteSearchResult(from:))
            .sorted { lhs, rhs in
                remoteSearchResultSort(lhs: lhs, rhs: rhs)
            }

        remoteSearchResults = Array(matches.prefix(Self.maxRemoteSearchResults))
        remoteSearchStatus.isRunning = false
        remoteSearchStatus.visitedCount = sourceEntries.count
        remoteSearchStatus.matchedCount = matches.count
        remoteSearchStatus.statusText = completedRemoteSearchStatusText(
            visitedCount: sourceEntries.count,
            matchedCount: matches.count
        )
        remoteSearchStatus.activity = Array(
            sourceEntries
                .prefix(4)
                .map { RemoteSearchActivity(path: $0.path, kind: $0.isDirectory ? .directory : .file) }
        )
        remoteSearchStatus.isResultTruncated = matches.count > Self.maxRemoteSearchResults
    }

    private func runRemoteSearch(
        query: String,
        scope: RemoteSearchScope,
        rootPath: String,
        generation: Int
    ) async {
        var matches: [RemoteSearchResult] = []
        var matchedPaths: Set<String> = []
        var visitedCount = 0
        var matchedCount = 0
        var recentActivity: [RemoteSearchActivity] = []
        var lastUIUpdate = Date.distantPast

        func publishProgress(force: Bool = false, errorMessage: String? = nil) {
            let now = Date()
            guard force || now.timeIntervalSince(lastUIUpdate) >= 0.12 else { return }
            lastUIUpdate = now
            guard remoteSearchGeneration == generation else { return }

            remoteSearchResults = Array(matches.prefix(Self.maxRemoteSearchResults))
            remoteSearchStatus.isRunning = true
            remoteSearchStatus.visitedCount = visitedCount
            remoteSearchStatus.matchedCount = matchedCount
            remoteSearchStatus.activity = recentActivity
            remoteSearchStatus.errorMessage = errorMessage
            remoteSearchStatus.isResultTruncated = matchedCount > Self.maxRemoteSearchResults
            remoteSearchStatus.statusText = runningRemoteSearchStatusText(
                visitedCount: visitedCount,
                matchedCount: matchedCount
            )
        }

        func completeSearch(errorMessage: String? = nil) {
            guard remoteSearchGeneration == generation else { return }

            remoteSearchResults = Array(
                matches
                    .sorted { lhs, rhs in
                        remoteSearchResultSort(lhs: lhs, rhs: rhs)
                    }
                    .prefix(Self.maxRemoteSearchResults)
            )
            remoteSearchStatus.isRunning = false
            remoteSearchStatus.visitedCount = visitedCount
            remoteSearchStatus.matchedCount = matchedCount
            remoteSearchStatus.activity = errorMessage == nil ? recentActivity : []
            remoteSearchStatus.errorMessage = errorMessage
            remoteSearchStatus.isResultTruncated = matchedCount > Self.maxRemoteSearchResults
            remoteSearchStatus.statusText = completedRemoteSearchStatusText(
                visitedCount: visitedCount,
                matchedCount: matchedCount
            )
            remoteSearchTask = nil
        }

        func handleVisitedPath(_ rawPath: String, isDirectory: Bool) {
            let normalizedPath = normalizeRemoteDirectoryPath(rawPath)
            guard normalizedPath != "/" else { return }

            visitedCount += 1
            recentActivity = appendRemoteSearchActivity(
                RemoteSearchActivity(
                    path: normalizedPath,
                    kind: isDirectory ? .directory : .file
                ),
                to: recentActivity
            )

            let itemName = normalizedPath == "/" ? "/" : URL(fileURLWithPath: normalizedPath).lastPathComponent
            if itemName.localizedCaseInsensitiveContains(query),
               matchedPaths.insert(normalizedPath).inserted
            {
                matchedCount += 1
                matches.append(
                    RemoteSearchResult(
                        path: normalizedPath,
                        name: itemName,
                        parentPath: remoteSearchParentPath(for: normalizedPath),
                        isDirectory: isDirectory
                    )
                )
                publishProgress(force: true)
                return
            }

            publishProgress()
        }

        do {
            let didUseStreamingSearch = try await streamRemoteSearch(
                rootPath: rootPath,
                generation: generation,
                onVisit: handleVisitedPath
            )

            if !didUseStreamingSearch {
                try await recursiveRemoteSearchFallback(
                    query: query,
                    rootPath: rootPath,
                    generation: generation,
                    onVisit: handleVisitedPath
                )
            }

            completeSearch()
        } catch is CancellationError {
            guard remoteSearchGeneration == generation else { return }
            remoteSearchTask = nil
            remoteSearchStatus.isRunning = false
            remoteSearchStatus.activity = []
            remoteSearchStatus.statusText = completedRemoteSearchStatusText(
                visitedCount: visitedCount,
                matchedCount: matchedCount
            )
            remoteSearchResults = Array(matches.prefix(Self.maxRemoteSearchResults))
        } catch {
            if visitedCount == 0 {
                do {
                    try await recursiveRemoteSearchFallback(
                        query: query,
                        rootPath: rootPath,
                        generation: generation,
                        onVisit: handleVisitedPath
                    )
                    completeSearch()
                } catch is CancellationError {
                    guard remoteSearchGeneration == generation else { return }
                    remoteSearchTask = nil
                    remoteSearchStatus.isRunning = false
                    remoteSearchStatus.activity = []
                    remoteSearchStatus.statusText = completedRemoteSearchStatusText(
                        visitedCount: visitedCount,
                        matchedCount: matchedCount
                    )
                    remoteSearchResults = Array(matches.prefix(Self.maxRemoteSearchResults))
                } catch {
                    completeSearch(errorMessage: error.localizedDescription)
                }
            } else {
                completeSearch(errorMessage: error.localizedDescription)
            }
        }
    }

    private func streamRemoteSearch(
        rootPath: String,
        generation: Int,
        onVisit: (String, Bool) -> Void
    ) async throws -> Bool {
        let stream = try await sftpClient.streamRemoteShellCommand(
            Self.makeRemoteSearchShellCommand(rootPath: rootPath)
        )

        var didReceiveEvent = false
        var buffer = ""
        for try await chunk in stream {
            try Task.checkCancellation()
            guard remoteSearchGeneration == generation else {
                throw CancellationError()
            }

            buffer += chunk
            while let newlineIndex = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                guard let event = parseRemoteSearchEvent(line) else { continue }
                didReceiveEvent = true
                onVisit(event.path, event.isDirectory)
            }
        }

        if let event = parseRemoteSearchEvent(buffer) {
            didReceiveEvent = true
            onVisit(event.path, event.isDirectory)
        }

        return didReceiveEvent
    }

    private func recursiveRemoteSearchFallback(
        query: String,
        rootPath: String,
        generation: Int,
        onVisit: (String, Bool) -> Void
    ) async throws {
        _ = query
        var pendingDirectories = [rootPath]
        var visitedDirectories = Set<String>()

        while let directoryPath = pendingDirectories.first {
            try Task.checkCancellation()
            guard remoteSearchGeneration == generation else {
                throw CancellationError()
            }

            pendingDirectories.removeFirst()
            let normalizedDirectoryPath = normalizeRemoteDirectoryPath(directoryPath)
            guard visitedDirectories.insert(normalizedDirectoryPath).inserted else { continue }

            let entries: [RemoteFileEntry]
            do {
                entries = try await sftpClient.list(path: normalizedDirectoryPath)
            } catch {
                continue
            }

            for entry in entries {
                try Task.checkCancellation()
                guard remoteSearchGeneration == generation else {
                    throw CancellationError()
                }

                let normalizedPath = normalizeRemoteDirectoryPath(entry.path)
                onVisit(normalizedPath, entry.isDirectory)
                if entry.isDirectory {
                    pendingDirectories.append(normalizedPath)
                }
            }
        }
    }

    private func appendRemoteSearchActivity(
        _ item: RemoteSearchActivity,
        to activity: [RemoteSearchActivity]
    ) -> [RemoteSearchActivity] {
        var updated = activity.filter { $0.path != item.path }
        updated.insert(item, at: 0)
        if updated.count > 6 {
            updated.removeLast(updated.count - 6)
        }
        return updated
    }

    private func remoteSearchParentPath(for path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func makeRemoteSearchResult(from entry: RemoteFileEntry) -> RemoteSearchResult {
        RemoteSearchResult(
            path: entry.path,
            name: remoteSearchEntryName(entry),
            parentPath: remoteSearchParentPath(for: entry.path),
            isDirectory: entry.isDirectory
        )
    }

    private func remoteSearchEntryName(_ entry: RemoteFileEntry) -> String {
        let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("/") {
            let candidate = URL(fileURLWithPath: entry.path).lastPathComponent
            return candidate.isEmpty ? entry.path : candidate
        }
        return trimmed
    }

    private func remoteSearchResultSort(lhs: RemoteSearchResult, rhs: RemoteSearchResult) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }

        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }

        return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    private func initialRemoteSearchStatusText(scope: RemoteSearchScope, rootPath: String) -> String {
        switch scope {
        case .currentDirectory:
            return String(format: tr("Searching %@"), rootPath)
        case .currentDirectoryRecursive:
            return String(format: tr("Searching %@ recursively"), rootPath)
        case .entireServer:
            return tr("Searching the entire server")
        }
    }

    private func runningRemoteSearchStatusText(visitedCount: Int, matchedCount: Int) -> String {
        String(format: tr("Scanning %lld items · %lld matches"), Int64(visitedCount), Int64(matchedCount))
    }

    private func completedRemoteSearchStatusText(visitedCount: Int, matchedCount: Int) -> String {
        String(format: tr("Scanned %lld items · %lld matches"), Int64(visitedCount), Int64(matchedCount))
    }

    private func parseRemoteSearchEvent(_ rawLine: String) -> (path: String, isDirectory: Bool)? {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let kind = String(parts[0])
        let path = String(parts[1])
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (path: path, isDirectory: kind == "d")
    }

    private static func makeRemoteSearchShellCommand(rootPath: String) -> String {
        let quotedRootPath = quoteShellArgument(rootPath)
        return """
        LC_ALL=C find \(quotedRootPath) -mindepth 1 -print 2>/dev/null | while IFS= read -r path; do if [ -d "$path" ]; then kind=d; else kind=f; fi; printf '%s\\t%s\\n' "$kind" "$path"; done
        """
    }

    private func executeTransfer(itemID: UUID) async {
        do {
            try await transferCenter.acquireSlot()
        } catch is CancellationError {
            markTransferStopped(itemID: itemID)
            return
        } catch {
            return
        }
        defer {
            Task {
                await transferCenter.releaseSlot()
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            markTransferStopped(itemID: itemID)
            return
        }

        guard let idx = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        var item = transferQueue[idx]
        if item.status == .stopped {
            return
        }

        let conflictOutcome = await resolveConflictOutcome(for: item)
        do {
            try Task.checkCancellation()
        } catch {
            markTransferStopped(itemID: itemID)
            return
        }

        var destinationExistedBeforeTransfer = false
        switch conflictOutcome {
        case .skip(let reason):
            transferQueue[idx].status = .skipped
            transferQueue[idx].message = reason
            clearTransferSpeedState(itemID: itemID)
            return
        case .proceed(let destinationPath):
            transferQueue[idx].destinationPath = destinationPath
            item.destinationPath = destinationPath
            destinationExistedBeforeTransfer = item.direction == .download
                && FileManager.default.fileExists(atPath: destinationPath)
            transferQueue[idx].status = .running
            transferQueue[idx].speedBytesPerSecond = nil
            transferQueue[idx].lastProgressSampleBytes = 0
            transferQueue[idx].lastProgressSampleDate = nil
        }

        FileTransferDiagnostics.append(
            "transfer start direction=\(item.direction.rawValue) source=\(item.sourcePath) destination=\(item.destinationPath)"
        )

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
                let destinationURL = URL(fileURLWithPath: item.destinationPath)
                let attributes = try await sftpClient.stat(path: item.sourcePath)
                if attributes.isDirectory {
                    FileTransferDiagnostics.append(
                        "materialize directory root remote=\(item.sourcePath) local=\(destinationURL.path)"
                    )
                    let entry = RemoteFileEntry(
                        name: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
                        path: item.sourcePath,
                        size: attributes.size,
                        permissions: attributes.permissions,
                        owner: attributes.owner,
                        group: attributes.group,
                        isDirectory: true,
                        modifiedAt: attributes.modifiedAt
                    )
                    try await downloadDirectoryTransfer(entry, to: destinationURL, itemID: itemID)
                } else {
                    try await sftpClient.download(
                        path: item.sourcePath,
                        to: destinationURL,
                        progress: { [weak self] snapshot in
                            Task { @MainActor in
                                self?.updateTransferProgress(itemID: itemID, snapshot: snapshot)
                            }
                        }
                    )
                }
                guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw NSError(
                        domain: "Remora.FileTransfer",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Download finished but local path is missing: \(destinationURL.path)"]
                    )
                }
            }

            if let doneIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                if transferQueue[doneIdx].status == .stopped || Task.isCancelled {
                    cleanupStoppedDownloadIfNeeded(item: item, destinationExistedBeforeTransfer: destinationExistedBeforeTransfer)
                    markTransferStopped(itemID: itemID)
                    return
                }
                transferQueue[doneIdx].status = .success
                clearTransferSpeedState(itemID: itemID)
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
            if error is CancellationError || Task.isCancelled {
                cleanupStoppedDownloadIfNeeded(item: item, destinationExistedBeforeTransfer: destinationExistedBeforeTransfer)
                markTransferStopped(itemID: itemID)
                FileTransferDiagnostics.append(
                    "transfer stopped direction=\(item.direction.rawValue) source=\(item.sourcePath) destination=\(item.destinationPath)"
                )
                return
            }

            if let failedIdx = transferQueue.firstIndex(where: { $0.id == itemID }) {
                transferQueue[failedIdx].status = .failed
                clearTransferSpeedState(itemID: itemID)
                transferQueue[failedIdx].message = FileTransferDiagnostics.failureMessage(for: error)
                let failedItem = transferQueue[failedIdx]
                FileTransferDiagnostics.append(
                    "transfer failed direction=\(failedItem.direction.rawValue) source=\(failedItem.sourcePath) destination=\(failedItem.destinationPath) reason=\(error.localizedDescription)"
                )
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
        let snapshot = TransferQueueAggregateSnapshot.resolve(
            items: transferQueue,
            currentBatchID: currentTransferBatchID,
            runningFallbackProgress: 0.1
        )
        guard snapshot.status != .idle else { return nil }
        return snapshot.progress
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

    private func materializeRemoteItem(_ entry: RemoteFileEntry, to localURL: URL) async throws {
        try Task.checkCancellation()
        if entry.isDirectory {
            FileTransferDiagnostics.append(
                "enter directory remote=\(entry.path) local=\(localURL.path)"
            )
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            let children = try await sftpClient.list(path: entry.path)
            FileTransferDiagnostics.append(
                "list directory remote=\(entry.path) children=\(children.count)"
            )
            for child in children {
                try Task.checkCancellation()
                let childURL = localURL.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                try await materializeRemoteItem(child, to: childURL)
            }
            return
        }

        FileTransferDiagnostics.append(
            "download file remote=\(entry.path) local=\(localURL.path)"
        )
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try await sftpClient.download(path: entry.path, to: localURL, progress: nil)
    }

    private func downloadDirectoryTransfer(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        itemID: UUID
    ) async throws {
        let plan = try await makeDirectoryDownloadPlan(for: entry)
        if let index = transferQueue.firstIndex(where: { $0.id == itemID }) {
            transferQueue[index].totalBytes = max(plan.totalFileBytes, 0)
            transferQueue[index].bytesTransferred = 0
        }

        var completedBytes: Int64 = 0
        try await materializeDirectoryPlanNode(
            plan,
            to: localURL,
            itemID: itemID,
            completedBytes: &completedBytes,
            totalBytes: plan.totalFileBytes
        )
    }

    private func makeDirectoryDownloadPlan(for entry: RemoteFileEntry) async throws -> DirectoryDownloadPlanNode {
        try Task.checkCancellation()
        guard entry.isDirectory else {
            return DirectoryDownloadPlanNode(entry: entry, children: [], totalFileBytes: max(entry.size, 0))
        }

        let children = try await sftpClient.list(path: entry.path)
        var plannedChildren: [DirectoryDownloadPlanNode] = []
        plannedChildren.reserveCapacity(children.count)
        var totalBytes: Int64 = 0

        for child in children {
            try Task.checkCancellation()
            let childPlan = try await makeDirectoryDownloadPlan(for: child)
            plannedChildren.append(childPlan)
            totalBytes += childPlan.totalFileBytes
        }

        return DirectoryDownloadPlanNode(entry: entry, children: plannedChildren, totalFileBytes: totalBytes)
    }

    private func materializeDirectoryPlanNode(
        _ node: DirectoryDownloadPlanNode,
        to localURL: URL,
        itemID: UUID,
        completedBytes: inout Int64,
        totalBytes: Int64
    ) async throws {
        try Task.checkCancellation()
        if node.entry.isDirectory {
            FileTransferDiagnostics.append(
                "enter directory remote=\(node.entry.path) local=\(localURL.path)"
            )
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            for child in node.children {
                try Task.checkCancellation()
                let childURL = localURL.appendingPathComponent(child.entry.name, isDirectory: child.entry.isDirectory)
                try await materializeDirectoryPlanNode(
                    child,
                    to: childURL,
                    itemID: itemID,
                    completedBytes: &completedBytes,
                    totalBytes: totalBytes
                )
            }
            return
        }

        FileTransferDiagnostics.append(
            "download file remote=\(node.entry.path) local=\(localURL.path)"
        )
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let completedBytesBeforeFile = completedBytes
        try await sftpClient.download(
            path: node.entry.path,
            to: localURL,
            progress: { [weak self] snapshot in
                Task { @MainActor in
                    self?.updateDirectoryTransferProgress(
                        itemID: itemID,
                        completedBytes: completedBytesBeforeFile + snapshot.bytesTransferred,
                        totalBytes: totalBytes
                    )
                }
            }
        )
        completedBytes += node.entry.size
        updateDirectoryTransferProgress(itemID: itemID, completedBytes: completedBytes, totalBytes: totalBytes)
    }

    private func materializeRemoteItem(at remotePath: String, to localURL: URL) async throws {
        let attributes = try await sftpClient.stat(path: remotePath)
        let entry = RemoteFileEntry(
            name: URL(fileURLWithPath: remotePath).lastPathComponent,
            path: remotePath,
            size: attributes.size,
            permissions: attributes.permissions,
            owner: attributes.owner,
            group: attributes.group,
            isDirectory: attributes.isDirectory,
            modifiedAt: attributes.modifiedAt
        )
        try await materializeRemoteItem(entry, to: localURL)
    }

    private func uploadExtractedItem(_ localURL: URL, toRemoteBasePath remoteBasePath: String) async throws {
        let values = try? localURL.resourceValues(forKeys: [.isDirectoryKey])
        let targetPath = normalizedRemotePath(base: remoteBasePath, child: localURL.lastPathComponent)
        guard let resolvedTargetPath = await resolveRemoteConflictPath(for: targetPath) else { return }

        if values?.isDirectory == true {
            if !(await remotePathExists(resolvedTargetPath)) {
                try await sftpClient.mkdir(path: resolvedTargetPath)
            }
            let children = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for child in children {
                try await uploadExtractedItem(child, toRemoteBasePath: resolvedTargetPath)
            }
            return
        }

        try await sftpClient.upload(fileURL: localURL, to: resolvedTargetPath, progress: nil)
    }

    private func ensureRemoteDirectoryExists(_ path: String) async throws {
        let normalizedPath = normalizeRemoteDirectoryPath(path)
        guard normalizedPath != "/" else { return }
        guard !(await remotePathExists(normalizedPath)) else { return }

        let parent = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
        let normalizedParent = parent.isEmpty ? "/" : parent
        if normalizedParent != normalizedPath {
            try await ensureRemoteDirectoryExists(normalizedParent)
        }
        try await sftpClient.mkdir(path: normalizedPath)
    }

    private func enqueueUploadFile(localURL: URL, destinationPath: String) {
        let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let item = TransferItem(
            batchID: prepareBatchIDForNewTransfer(),
            direction: .upload,
            name: localURL.lastPathComponent,
            sourcePath: localURL.path,
            destinationPath: destinationPath,
            totalBytes: fileSize
        )
        transferQueue.append(item)
        startTransferTask(for: item.id)
    }

    private func startTransferTask(for itemID: UUID) {
        transferTasks[itemID]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeTransfer(itemID: itemID)
            self.transferTasks.removeValue(forKey: itemID)
        }
        transferTasks[itemID] = task
    }

    private func cancelTrackedTransfers(clearQueue: Bool) {
        for task in transferTasks.values {
            task.cancel()
        }
        transferTasks.removeAll()
        if clearQueue {
            transferQueue.removeAll()
        }
    }

    private func prepareBatchIDForNewTransfer() -> Int {
        if let currentTransferBatchID {
            let currentBatchItems = transferQueue.filter { $0.batchID == currentTransferBatchID }
            if currentBatchItems.isEmpty == false,
               currentBatchItems.contains(where: { $0.status.isTerminal == false }) {
                return currentTransferBatchID
            }
        }

        nextTransferBatchSeed += 1
        currentTransferBatchID = nextTransferBatchSeed
        return nextTransferBatchSeed
    }

    private func markTransferStopped(itemID: UUID) {
        guard let index = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        transferQueue[index].status = .stopped
        clearTransferSpeedState(itemID: itemID)
        transferQueue[index].message = tr("Stopped")
    }

    private func cleanupStoppedDownloadIfNeeded(
        item: TransferItem,
        destinationExistedBeforeTransfer: Bool
    ) {
        guard item.direction == .download else { return }
        guard destinationExistedBeforeTransfer == false else { return }
        try? FileManager.default.removeItem(atPath: item.destinationPath)
    }

    private func updateTransferProgress(itemID: UUID, snapshot: TransferProgressSnapshot) {
        guard let index = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        applyTransferProgressSample(
            index: index,
            bytesTransferred: snapshot.bytesTransferred,
            totalBytes: snapshot.totalBytes
        )
    }

    private func updateDirectoryTransferProgress(itemID: UUID, completedBytes: Int64, totalBytes: Int64) {
        guard let index = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        applyTransferProgressSample(
            index: index,
            bytesTransferred: min(max(completedBytes, 0), max(totalBytes, 0)),
            totalBytes: max(totalBytes, 0)
        )
    }

    private func applyTransferProgressSample(index: Int, bytesTransferred: Int64, totalBytes: Int64?) {
        let now = Date()
        let clampedBytes = max(bytesTransferred, 0)
        let currentBytes = transferQueue[index].bytesTransferred

        // Progress callbacks should be monotonic. Ignore stale samples that arrive out of order
        // so a delayed zero-byte update cannot erase later observed progress.
        guard clampedBytes >= currentBytes else {
            return
        }

        let previousBytes = transferQueue[index].lastProgressSampleBytes
        let previousDate = transferQueue[index].lastProgressSampleDate

        transferQueue[index].bytesTransferred = clampedBytes
        if let totalBytes {
            transferQueue[index].totalBytes = max(totalBytes, 0)
        }

        if let previousBytes, let previousDate {
            let deltaBytes = clampedBytes - previousBytes
            let deltaTime = now.timeIntervalSince(previousDate)
            if deltaBytes > 0, deltaTime > 0 {
                transferQueue[index].speedBytesPerSecond = max(Int64(Double(deltaBytes) / deltaTime), 0)
            }
        }

        transferQueue[index].lastProgressSampleBytes = clampedBytes
        transferQueue[index].lastProgressSampleDate = now
    }

    private func clearTransferSpeedState(itemID: UUID) {
        guard let index = transferQueue.firstIndex(where: { $0.id == itemID }) else { return }
        transferQueue[index].speedBytesPerSecond = nil
        transferQueue[index].lastProgressSampleBytes = nil
        transferQueue[index].lastProgressSampleDate = nil
    }

    private func beginArchiveProgress(status: String, progress: Double) {
        archiveOperationStatusText = status
        archiveOperationProgress = min(max(progress, 0), 1)
    }

    private func updateArchiveProgress(status: String, progress: Double) {
        archiveOperationStatusText = status
        archiveOperationProgress = min(max(progress, 0), 1)
    }

    private func clearArchiveProgress() {
        archiveOperationStatusText = nil
        archiveOperationProgress = nil
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
        deduplicateInFlight: Bool,
        bindingGeneration: Int? = nil
    ) async {
        let bindingGeneration = bindingGeneration ?? sftpBindingGeneration
        // Drop stale async work from previous bindings.
        guard isActiveBindingGeneration(bindingGeneration) else { return }
        let path = normalizeRemoteDirectoryPath(rawPath)

        if preferCachedFirst, let cached = remoteDirectoryCache[path] {
            guard isActiveBindingGeneration(bindingGeneration) else { return }
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

        guard isActiveBindingGeneration(bindingGeneration) else { return }
        if deduplicateInFlight, remoteRefreshInFlightPaths.contains(path) {
            updateRemoteLoadingState()
            return
        }

        remoteRefreshInFlightPaths.insert(path)
        updateRemoteLoadingState()
        defer {
            if isActiveBindingGeneration(bindingGeneration) {
                remoteRefreshInFlightPaths.remove(path)
                updateRemoteLoadingState()
            }
        }

        do {
            let entries = try await sftpClient.list(path: path)
            guard isActiveBindingGeneration(bindingGeneration) else { return }
            let sorted = sortRemoteEntries(entries)
            remoteDirectoryCache[path] = CachedRemoteDirectory(entries: sorted, fetchedAt: Date())
            if remoteDirectoryPath == path {
                remoteEntries = sorted
                remoteLoadErrorMessage = nil
            }
        } catch {
            guard isActiveBindingGeneration(bindingGeneration) else { return }
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

    private func isActiveBindingGeneration(_ bindingGeneration: Int) -> Bool {
        bindingGeneration == sftpBindingGeneration
    }

    private static func makeTemporaryTextDocumentURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-text-doc-\(UUID().uuidString)", isDirectory: false)
    }

    private static func makeArchiveWorkspaceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-archive-workspace-\(UUID().uuidString)", isDirectory: true)
    }

    private static func decodeTextDocument(
        path: String,
        payload: Data,
        modifiedAt: Date?
    ) async throws -> RemoteTextDocument {
        try await Task.detached(priority: .userInitiated) {
            if let utf8 = String(data: payload, encoding: .utf8) {
                return RemoteTextDocument(
                    path: path,
                    text: utf8,
                    encoding: "UTF-8",
                    modifiedAt: modifiedAt,
                    isReadOnly: false
                )
            }

            if let latin1 = String(data: payload, encoding: .isoLatin1) {
                return RemoteTextDocument(
                    path: path,
                    text: latin1,
                    encoding: "ISO-8859-1",
                    modifiedAt: modifiedAt,
                    isReadOnly: false
                )
            }

            throw SFTPClientError.unsupportedOperation("edit-binary-file")
        }.value
    }

    private static func quoteShellArgument(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
