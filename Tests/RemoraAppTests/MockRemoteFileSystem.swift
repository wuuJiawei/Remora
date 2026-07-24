import Foundation
import RemoraCore

actor MockRemoteFileSystem: RemoteFileSystem {
    struct Configuration: Sendable {
        var listDelay: Duration?
        var readDelay: Duration?
        var writeDelay: Duration?
        var maximumReadChunkSize: Int?
        var maximumWriteChunkSize: Int?
        var allowedAttributeCalls: Int?
        var failingReadPaths: Set<String> = []
        var reportedSizes: [String: Int64] = [:]
    }

    private struct StoredFile: Sendable {
        var data: Data
        var attributes: RemoteFileAttributes
    }

    private var files: [String: StoredFile] = [:]
    private var directories: [String: RemoteFileAttributes] = [:]
    private var symbolicLinks: [String: String] = [:]
    private var configuration: Configuration
    private var listCalls = 0
    private var attributeCalls = 0
    private var readOpenCalls = 0
    private var openedReadPaths: [String] = []
    private var cancelledReadPaths: [String] = []
    private var largestRequestedReadSize = 0
    private var closed = false

    init(configuration: Configuration = Configuration(), includeDefaultFixtures: Bool = true) {
        self.configuration = configuration
        let now = Date()
        directories["/"] = Self.directoryAttributes(modifiedAt: now)
        if includeDefaultFixtures {
            directories["/logs"] = Self.directoryAttributes(modifiedAt: now)
            let readme = Data("Remora mock SFTP".utf8)
            files["/README.txt"] = StoredFile(
                data: readme,
                attributes: Self.fileAttributes(size: Int64(readme.count), modifiedAt: now)
            )
            let log = Data("service started".utf8)
            files["/logs/app.log"] = StoredFile(
                data: log,
                attributes: Self.fileAttributes(size: Int64(log.count), modifiedAt: now)
            )
        }
    }

    func capabilities() -> RemoteFileSystemCapabilities {
        RemoteFileSystemCapabilities(
            supportsSymbolicLinks: true,
            supportsAtomicRename: true,
            supportsAttributeUpdates: true
        )
    }

    func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        try ensureOpen(path: path)
        if let delay = configuration.listDelay {
            try await Task.sleep(for: delay)
        }
        listCalls += 1
        let directory = normalize(path)
        guard directories[directory] != nil else {
            throw operationError(.notFound, path: directory)
        }

        let prefix = directory == "/" ? "/" : directory + "/"
        var childNames = Set<String>()
        for candidate in files.keys {
            collectImmediateChildName(candidate, prefix: prefix, into: &childNames)
        }
        for candidate in directories.keys where candidate != directory {
            collectImmediateChildName(candidate, prefix: prefix, into: &childNames)
        }
        for candidate in symbolicLinks.keys {
            collectImmediateChildName(candidate, prefix: prefix, into: &childNames)
        }

        return childNames.sorted().compactMap { name in
            let childPath = join(parent: directory, name: name)
            if let attributes = directories[childPath] {
                return entry(name: name, path: childPath, attributes: attributes)
            }
            if let file = files[childPath] {
                return entry(name: name, path: childPath, attributes: file.attributes)
            }
            if symbolicLinks[childPath] != nil {
                return RemoteFileEntry(
                    name: name,
                    path: childPath,
                    size: 0,
                    permissions: 0o777,
                    owner: "mock",
                    group: "mock",
                    isDirectory: false,
                    isSymbolicLink: true,
                    modifiedAt: Date()
                )
            }
            return nil
        }
    }

    func attributes(path: String, followSymbolicLinks: Bool) throws -> RemoteFileAttributes {
        try ensureOpen(path: path)
        attributeCalls += 1
        if let allowed = configuration.allowedAttributeCalls, attributeCalls > allowed {
            throw operationError(.connectionLost, path: normalize(path))
        }

        let requestedPath = normalize(path)
        let resolvedPath = try resolvePath(requestedPath, followSymbolicLinks: followSymbolicLinks)
        if let file = files[resolvedPath] {
            var attributes = file.attributes
            attributes.size = configuration.reportedSizes[requestedPath] ?? Int64(file.data.count)
            return attributes
        }
        if let directory = directories[resolvedPath] {
            return directory
        }
        if !followSymbolicLinks, symbolicLinks[requestedPath] != nil {
            return RemoteFileAttributes(
                permissions: 0o777,
                owner: "mock",
                group: "mock",
                size: 0,
                modifiedAt: Date(),
                isDirectory: false,
                isSymbolicLink: true
            )
        }
        throw operationError(.notFound, path: requestedPath)
    }

    func openFile(
        path: String,
        options: RemoteFileOpenOptions,
        attributes: RemoteFileAttributes?
    ) async throws -> any RemoteFileHandleProtocol {
        try ensureOpen(path: path)
        let requestedPath = normalize(path)
        let resolvedPath = try resolvePath(requestedPath, followSymbolicLinks: true)

        if options.contains(.read) && !options.contains(.write) {
            guard let file = files[resolvedPath] else {
                throw operationError(.notFound, path: requestedPath)
            }
            readOpenCalls += 1
            openedReadPaths.append(requestedPath)
            let shouldFail = configuration.failingReadPaths.contains(requestedPath)
            return MockRemoteFileHandle(
                mode: .read(file.data),
                readDelay: configuration.readDelay,
                writeDelay: nil,
                maximumReadChunkSize: configuration.maximumReadChunkSize,
                maximumWriteChunkSize: nil,
                failReads: shouldFail,
                onReadRequest: { [weak self] requestedSize in
                    await self?.recordReadRequest(size: requestedSize)
                },
                onReadCancellation: { [weak self] in
                    await self?.recordReadCancellation(path: requestedPath)
                },
                onClose: nil
            )
        }

        guard options.contains(.write) else {
            throw operationError(.unsupported, path: requestedPath)
        }
        if options.contains(.exclusive), files[resolvedPath] != nil {
            throw operationError(.alreadyExists, path: requestedPath)
        }
        if files[resolvedPath] == nil, !options.contains(.create) {
            throw operationError(.notFound, path: requestedPath)
        }
        guard directories[parentPath(of: resolvedPath)] != nil else {
            throw operationError(.notFound, path: parentPath(of: resolvedPath))
        }

        let existing = files[resolvedPath]
        let initialData: Data
        let initialOffset: Int
        if options.contains(.truncate) {
            initialData = Data()
            initialOffset = 0
        } else {
            initialData = existing?.data ?? Data()
            initialOffset = options.contains(.append) ? initialData.count : 0
        }
        let template = attributes ?? existing?.attributes ?? Self.fileAttributes(size: 0, modifiedAt: Date())

        return MockRemoteFileHandle(
            mode: .write(initialData, offset: initialOffset),
            readDelay: nil,
            writeDelay: configuration.writeDelay,
            maximumReadChunkSize: nil,
            maximumWriteChunkSize: configuration.maximumWriteChunkSize,
            failReads: false,
            onReadRequest: nil,
            onReadCancellation: nil,
            onClose: { [weak self] data in
                await self?.commitFile(path: resolvedPath, data: data, template: template)
            }
        )
    }

    func createDirectory(path: String, attributes: RemoteFileAttributes?) throws {
        try ensureOpen(path: path)
        let directory = normalize(path)
        guard directory != "/" else { return }
        guard files[directory] == nil, symbolicLinks[directory] == nil else {
            throw operationError(.alreadyExists, path: directory)
        }
        guard directories[directory] == nil else {
            throw operationError(.alreadyExists, path: directory)
        }
        guard directories[parentPath(of: directory)] != nil else {
            throw operationError(.notFound, path: parentPath(of: directory))
        }
        var value = attributes ?? Self.directoryAttributes(modifiedAt: Date())
        value.isDirectory = true
        value.isSymbolicLink = false
        directories[directory] = value
        touchParents(of: directory)
    }

    func removeFile(path: String) throws {
        try ensureOpen(path: path)
        let target = normalize(path)
        if files.removeValue(forKey: target) != nil || symbolicLinks.removeValue(forKey: target) != nil {
            touchParents(of: target)
            return
        }
        if directories[target] != nil {
            throw operationError(.invalidPath, path: target)
        }
        throw operationError(.notFound, path: target)
    }

    func removeDirectory(path: String) throws {
        try ensureOpen(path: path)
        let target = normalize(path)
        guard target != "/", directories[target] != nil else {
            throw operationError(target == "/" ? .invalidPath : .notFound, path: target)
        }
        let prefix = target + "/"
        let hasChildren = files.keys.contains { $0.hasPrefix(prefix) }
            || directories.keys.contains { $0.hasPrefix(prefix) }
            || symbolicLinks.keys.contains { $0.hasPrefix(prefix) }
        guard !hasChildren else {
            throw operationError(.invalidPath, path: target)
        }
        directories[target] = nil
        touchParents(of: target)
    }

    func rename(from sourcePath: String, to destinationPath: String, overwrite: Bool) throws {
        try ensureOpen(path: sourcePath)
        let source = normalize(sourcePath)
        let destination = normalize(destinationPath)
        guard source != "/", destination != "/" else {
            throw operationError(.invalidPath, path: source)
        }
        guard directories[parentPath(of: destination)] != nil else {
            throw operationError(.notFound, path: parentPath(of: destination))
        }
        if itemExists(at: destination) {
            guard overwrite else {
                throw operationError(.alreadyExists, path: destination)
            }
            try removeItemRecursively(at: destination)
        }

        if var file = files.removeValue(forKey: source) {
            file.attributes.modifiedAt = Date()
            files[destination] = file
            touchParents(of: source)
            touchParents(of: destination)
            return
        }
        if let target = symbolicLinks.removeValue(forKey: source) {
            symbolicLinks[destination] = target
            touchParents(of: source)
            touchParents(of: destination)
            return
        }
        guard let sourceDirectory = directories.removeValue(forKey: source) else {
            throw operationError(.notFound, path: source)
        }

        directories[destination] = sourceDirectory
        let sourcePrefix = source + "/"
        let destinationPrefix = destination + "/"
        movePrefixedValues(in: &directories, from: sourcePrefix, to: destinationPrefix)
        movePrefixedValues(in: &files, from: sourcePrefix, to: destinationPrefix)
        movePrefixedValues(in: &symbolicLinks, from: sourcePrefix, to: destinationPrefix)
        touchParents(of: source)
        touchParents(of: destination)
    }

    func setAttributes(path: String, attributes: RemoteFileAttributes) throws {
        try ensureOpen(path: path)
        let target = normalize(path)
        if var file = files[target] {
            file.attributes.permissions = attributes.permissions
            file.attributes.owner = attributes.owner
            file.attributes.group = attributes.group
            file.attributes.modifiedAt = attributes.modifiedAt
            files[target] = file
            return
        }
        if var directory = directories[target] {
            directory.permissions = attributes.permissions
            directory.owner = attributes.owner
            directory.group = attributes.group
            directory.modifiedAt = attributes.modifiedAt
            directories[target] = directory
            return
        }
        throw operationError(.notFound, path: target)
    }

    func readSymbolicLink(path: String) throws -> String {
        try ensureOpen(path: path)
        let target = normalize(path)
        guard let value = symbolicLinks[target] else {
            throw operationError(.notFound, path: target)
        }
        return value
    }

    func createSymbolicLink(path: String, target: String) throws {
        try ensureOpen(path: path)
        let linkPath = normalize(path)
        guard !itemExists(at: linkPath) else {
            throw operationError(.alreadyExists, path: linkPath)
        }
        guard directories[parentPath(of: linkPath)] != nil else {
            throw operationError(.notFound, path: parentPath(of: linkPath))
        }
        symbolicLinks[linkPath] = target
        touchParents(of: linkPath)
    }

    func close() {
        closed = true
    }

    func isClosedForTesting() -> Bool {
        closed
    }

    func seedFile(data: Data, at path: String, attributes: RemoteFileAttributes? = nil) throws {
        let target = normalize(path)
        try ensureFixtureParents(for: target)
        files[target] = StoredFile(
            data: data,
            attributes: attributes ?? Self.fileAttributes(size: Int64(data.count), modifiedAt: Date())
        )
    }

    func seedDirectory(at path: String) throws {
        let target = normalize(path)
        try ensureFixtureParents(for: target + "/fixture")
        directories[target] = Self.directoryAttributes(modifiedAt: Date())
    }

    func fileData(at path: String) throws -> Data {
        let target = normalize(path)
        guard let file = files[target] else {
            throw operationError(.notFound, path: target)
        }
        return file.data
    }

    func executeArchiveCommand(_ command: String) throws -> String? {
        guard let markerRange = command.range(of: "# remora-archive ") else {
            return nil
        }
        let marker = command[markerRange.lowerBound...]
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let payloadText = marker.replacingOccurrences(of: "# remora-archive ", with: "")
        guard let payloadData = payloadText.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let operation = payload["op"] as? String
        else {
            throw operationError(.malformedResponse, path: nil)
        }

        switch operation {
        case "probe":
            return """
            tar=OK
            zip=OK
            unzip=OK
            sevenZip=7z
            unrar=OK
            gzip=OK
            """
        case "compress":
            guard let destination = payload["destination"] as? String,
                  let sources = payload["sources"] as? [String],
                  let parent = payload["parent"] as? String
            else {
                throw operationError(.malformedResponse, path: nil)
            }
            try createMockArchive(
                destinationPath: normalize(destination),
                sourceNames: sources,
                parentDirectory: normalize(parent)
            )
            return ""
        case "list":
            guard let archivePath = payload["archive"] as? String,
                  let format = payload["format"] as? String
            else {
                throw operationError(.malformedResponse, path: nil)
            }
            return try listMockArchiveEntries(
                archivePath: normalize(archivePath),
                format: format
            )
        case "extract":
            guard let archivePath = payload["archive"] as? String,
                  let destination = payload["destination"] as? String
            else {
                throw operationError(.malformedResponse, path: nil)
            }
            try extractMockArchive(
                archivePath: normalize(archivePath),
                destinationDirectory: normalize(destination)
            )
            return ""
        default:
            throw operationError(.unsupported, path: nil)
        }
    }

    func listCallCount() -> Int { listCalls }
    func attributeCallCount() -> Int { attributeCalls }
    func readOpenCallCount() -> Int { readOpenCalls }
    func readPaths() -> [String] { openedReadPaths }
    func cancelledReads() -> [String] { cancelledReadPaths }
    func maximumRequestedReadSize() -> Int { largestRequestedReadSize }

    private func commitFile(path: String, data: Data, template: RemoteFileAttributes) {
        var value = template
        value.size = Int64(data.count)
        value.modifiedAt = Date()
        value.isDirectory = false
        value.isSymbolicLink = false
        files[path] = StoredFile(data: data, attributes: value)
        touchParents(of: path)
    }

    private func recordReadRequest(size: Int) {
        largestRequestedReadSize = max(largestRequestedReadSize, size)
    }

    private func recordReadCancellation(path: String) {
        cancelledReadPaths.append(path)
    }

    private func createMockArchive(
        destinationPath: String,
        sourceNames: [String],
        parentDirectory: String
    ) throws {
        _ = try sourcePaths(parentDirectory: parentDirectory, sourceNames: sourceNames)
        try ensureFixtureParents(for: destinationPath)
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "parent": parentDirectory,
                "sources": sourceNames,
            ],
            options: [.sortedKeys]
        )
        files[destinationPath] = StoredFile(
            data: payload,
            attributes: Self.fileAttributes(size: Int64(payload.count), modifiedAt: Date())
        )
        touchParents(of: destinationPath)
    }

    private func listMockArchiveEntries(archivePath: String, format: String) throws -> String {
        let archive = try archivePayload(at: archivePath)
        let entries = try sourcePaths(
            parentDirectory: archive.parent,
            sourceNames: archive.sources
        ).flatMap { try archiveEntries(for: $0) }
        if format == "7z" || format == "rar" {
            return entries.map { "Path = \($0)" }.joined(separator: "\n")
        }
        return entries.joined(separator: "\n")
    }

    private func extractMockArchive(archivePath: String, destinationDirectory: String) throws {
        let archive = try archivePayload(at: archivePath)
        try ensureFixtureParents(for: destinationDirectory + "/fixture")
        directories[destinationDirectory] = directories[destinationDirectory]
            ?? Self.directoryAttributes(modifiedAt: Date())

        for source in try sourcePaths(
            parentDirectory: archive.parent,
            sourceNames: archive.sources
        ) {
            let name = URL(fileURLWithPath: source).lastPathComponent
            let destination = join(parent: destinationDirectory, name: name)
            try copyFixtureItem(from: source, to: destination)
        }
        touchParents(of: destinationDirectory)
    }

    private func archivePayload(at path: String) throws -> (parent: String, sources: [String]) {
        guard let file = files[path] else {
            throw operationError(.notFound, path: path)
        }
        guard let object = try JSONSerialization.jsonObject(with: file.data) as? [String: Any],
              let parent = object["parent"] as? String,
              let sources = object["sources"] as? [String]
        else {
            throw operationError(.malformedResponse, path: path)
        }
        return (normalize(parent), sources)
    }

    private func sourcePaths(parentDirectory: String, sourceNames: [String]) throws -> [String] {
        try sourceNames.map { name in
            let path = join(parent: parentDirectory, name: name)
            guard itemExists(at: path) else {
                throw operationError(.notFound, path: path)
            }
            return path
        }
    }

    private func archiveEntries(for sourcePath: String) throws -> [String] {
        let baseName = URL(fileURLWithPath: sourcePath).lastPathComponent
        if files[sourcePath] != nil || symbolicLinks[sourcePath] != nil {
            return [baseName]
        }
        guard directories[sourcePath] != nil else {
            throw operationError(.notFound, path: sourcePath)
        }

        let prefix = sourcePath + "/"
        let nestedDirectories = directories.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { baseName + "/" + $0.dropFirst(prefix.count) + "/" }
        let nestedFiles = files.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { baseName + "/" + $0.dropFirst(prefix.count) }
        let nestedLinks = symbolicLinks.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { baseName + "/" + $0.dropFirst(prefix.count) }
        return [baseName + "/"] + nestedDirectories + nestedFiles + nestedLinks
    }

    private func copyFixtureItem(from source: String, to destination: String) throws {
        if var file = files[source] {
            try ensureFixtureParents(for: destination)
            file.attributes.modifiedAt = Date()
            files[destination] = file
            return
        }
        if let linkTarget = symbolicLinks[source] {
            try ensureFixtureParents(for: destination)
            symbolicLinks[destination] = linkTarget
            return
        }
        guard var directory = directories[source] else {
            throw operationError(.notFound, path: source)
        }

        try ensureFixtureParents(for: destination + "/fixture")
        directory.modifiedAt = Date()
        directories[destination] = directory
        let sourcePrefix = source + "/"
        let destinationPrefix = destination + "/"
        for (path, attributes) in directories.filter({ $0.key.hasPrefix(sourcePrefix) }) {
            directories[destinationPrefix + path.dropFirst(sourcePrefix.count)] = attributes
        }
        for (path, file) in files.filter({ $0.key.hasPrefix(sourcePrefix) }) {
            files[destinationPrefix + path.dropFirst(sourcePrefix.count)] = file
        }
        for (path, target) in symbolicLinks.filter({ $0.key.hasPrefix(sourcePrefix) }) {
            symbolicLinks[destinationPrefix + path.dropFirst(sourcePrefix.count)] = target
        }
    }

    private func resolvePath(_ path: String, followSymbolicLinks: Bool) throws -> String {
        guard followSymbolicLinks else { return path }
        var result = path
        var visited = Set<String>()
        while let target = symbolicLinks[result] {
            guard visited.insert(result).inserted, visited.count <= 32 else {
                throw operationError(.invalidPath, path: path)
            }
            result = target.hasPrefix("/")
                ? normalize(target)
                : join(parent: parentPath(of: result), name: target)
        }
        return result
    }

    private func removeItemRecursively(at path: String) throws {
        if files.removeValue(forKey: path) != nil || symbolicLinks.removeValue(forKey: path) != nil {
            return
        }
        guard directories.removeValue(forKey: path) != nil else {
            throw operationError(.notFound, path: path)
        }
        let prefix = path + "/"
        files = files.filter { !$0.key.hasPrefix(prefix) }
        directories = directories.filter { !$0.key.hasPrefix(prefix) }
        symbolicLinks = symbolicLinks.filter { !$0.key.hasPrefix(prefix) }
    }

    private func movePrefixedValues<Value>(
        in storage: inout [String: Value],
        from sourcePrefix: String,
        to destinationPrefix: String
    ) {
        let moving = storage.filter { $0.key.hasPrefix(sourcePrefix) }
        for (path, value) in moving {
            storage[path] = nil
            let suffix = String(path.dropFirst(sourcePrefix.count))
            storage[destinationPrefix + suffix] = value
        }
    }

    private func collectImmediateChildName(
        _ candidate: String,
        prefix: String,
        into names: inout Set<String>
    ) {
        guard candidate.hasPrefix(prefix) else { return }
        let suffix = candidate.dropFirst(prefix.count)
        guard let component = suffix.split(separator: "/").first else { return }
        names.insert(String(component))
    }

    private func entry(name: String, path: String, attributes: RemoteFileAttributes) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            size: attributes.size,
            permissions: attributes.permissions,
            owner: attributes.owner,
            group: attributes.group,
            isDirectory: attributes.isDirectory,
            isSymbolicLink: attributes.isSymbolicLink,
            modifiedAt: attributes.modifiedAt
        )
    }

    private func ensureOpen(path: String) throws {
        guard !closed else {
            throw operationError(.connectionLost, path: normalize(path))
        }
    }

    private func ensureFixtureParents(for path: String) throws {
        let components = normalize(path).split(separator: "/").dropLast()
        var cursor = ""
        for component in components {
            cursor += "/\(component)"
            if directories[cursor] == nil {
                directories[cursor] = Self.directoryAttributes(modifiedAt: Date())
            }
        }
    }

    private func itemExists(at path: String) -> Bool {
        files[path] != nil || directories[path] != nil || symbolicLinks[path] != nil
    }

    private func touchParents(of path: String) {
        var parent = parentPath(of: path)
        while true {
            if var value = directories[parent] {
                value.modifiedAt = Date()
                directories[parent] = value
            }
            if parent == "/" { return }
            parent = parentPath(of: parent)
        }
    }

    private func normalize(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let prefixed = path.hasPrefix("/") ? path : "/\(path)"
        let normalized = URL(fileURLWithPath: prefixed).standardized.path
        return normalized.isEmpty ? "/" : normalized
    }

    private func parentPath(of path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func join(parent: String, name: String) -> String {
        normalize(parent == "/" ? "/\(name)" : "\(parent)/\(name)")
    }

    private func operationError(_ status: RemoteFileSystemStatus, path: String?) -> RemoteFileSystemOperationError {
        RemoteFileSystemOperationError(status: status, path: path)
    }

    private static func fileAttributes(size: Int64, modifiedAt: Date) -> RemoteFileAttributes {
        RemoteFileAttributes(
            permissions: 0o644,
            owner: "mock",
            group: "mock",
            size: size,
            modifiedAt: modifiedAt,
            isDirectory: false
        )
    }

    private static func directoryAttributes(modifiedAt: Date) -> RemoteFileAttributes {
        RemoteFileAttributes(
            permissions: 0o755,
            owner: "mock",
            group: "mock",
            size: 0,
            modifiedAt: modifiedAt,
            isDirectory: true
        )
    }
}

private actor MockRemoteFileHandle: RemoteFileHandleProtocol {
    enum Mode: Sendable {
        case read(Data)
        case write(Data, offset: Int)
    }

    nonisolated let id = UUID()

    private var mode: Mode
    private let readDelay: Duration?
    private let writeDelay: Duration?
    private let maximumReadChunkSize: Int?
    private let maximumWriteChunkSize: Int?
    private let failReads: Bool
    private let onReadRequest: (@Sendable (Int) async -> Void)?
    private let onReadCancellation: (@Sendable () async -> Void)?
    private let onClose: (@Sendable (Data) async -> Void)?
    private var readOffset = 0
    private var closed = false

    init(
        mode: Mode,
        readDelay: Duration?,
        writeDelay: Duration?,
        maximumReadChunkSize: Int?,
        maximumWriteChunkSize: Int?,
        failReads: Bool,
        onReadRequest: (@Sendable (Int) async -> Void)?,
        onReadCancellation: (@Sendable () async -> Void)?,
        onClose: (@Sendable (Data) async -> Void)?
    ) {
        self.mode = mode
        self.readDelay = readDelay
        self.writeDelay = writeDelay
        self.maximumReadChunkSize = maximumReadChunkSize
        self.maximumWriteChunkSize = maximumWriteChunkSize
        self.failReads = failReads
        self.onReadRequest = onReadRequest
        self.onReadCancellation = onReadCancellation
        self.onClose = onClose
    }

    func read(maximumBytes: Int) async throws -> Data {
        guard !closed else {
            throw RemoteFileSystemOperationError(status: .connectionLost)
        }
        await onReadRequest?(maximumBytes)
        do {
            try Task.checkCancellation()
            if let readDelay {
                try await Task.sleep(for: readDelay)
            }
            try Task.checkCancellation()
        } catch {
            await onReadCancellation?()
            throw error
        }
        guard !failReads else {
            throw RemoteFileSystemOperationError(status: .connectionLost)
        }
        guard case .read(let data) = mode else {
            throw RemoteFileSystemOperationError(status: .unsupported)
        }
        guard readOffset < data.count else { return Data() }
        let chunkSize = min(maximumBytes, maximumReadChunkSize ?? maximumBytes)
        let end = min(readOffset + max(chunkSize, 1), data.count)
        let chunk = data[readOffset ..< end]
        readOffset = end
        return Data(chunk)
    }

    func write(_ data: Data) async throws -> Int {
        guard !closed else {
            throw RemoteFileSystemOperationError(status: .connectionLost)
        }
        try Task.checkCancellation()
        if let writeDelay {
            try await Task.sleep(for: writeDelay)
        }
        try Task.checkCancellation()
        guard case .write(var buffer, let offset) = mode else {
            throw RemoteFileSystemOperationError(status: .unsupported)
        }
        let count = min(data.count, maximumWriteChunkSize ?? data.count)
        guard count > 0 else { return 0 }
        let end = offset + count
        if end > buffer.count {
            buffer.append(Data(repeating: 0, count: end - buffer.count))
        }
        buffer.replaceSubrange(offset ..< end, with: data.prefix(count))
        mode = .write(buffer, offset: end)
        return count
    }

    func close() async {
        guard !closed else { return }
        closed = true
        guard case .write(let data, _) = mode else { return }
        await onClose?(data)
    }
}
