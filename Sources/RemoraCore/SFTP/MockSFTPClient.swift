import Foundation

public actor MockSFTPClient: SFTPClientProtocol {
    private struct StoredFile: Sendable {
        var data: Data
        var attributes: RemoteFileAttributes
    }

    private var files: [String: StoredFile]
    private var directories: [String: RemoteFileAttributes]

    public init() {
        let now = Date()
        let readmeData = Data("Remora mock SFTP".utf8)
        let logData = Data("service started".utf8)

        files = [
            "/README.txt": StoredFile(
                data: readmeData,
                attributes: RemoteFileAttributes(
                    permissions: 0o644,
                    owner: "mock",
                    group: "mock",
                    size: Int64(readmeData.count),
                    modifiedAt: now,
                    isDirectory: false
                )
            ),
            "/logs/app.log": StoredFile(
                data: logData,
                attributes: RemoteFileAttributes(
                    permissions: 0o644,
                    owner: "mock",
                    group: "mock",
                    size: Int64(logData.count),
                    modifiedAt: now,
                    isDirectory: false
                )
            ),
        ]

        directories = [
            "/": RemoteFileAttributes(
                permissions: 0o755,
                owner: "mock",
                group: "mock",
                size: 0,
                modifiedAt: now,
                isDirectory: true
            ),
            "/logs": RemoteFileAttributes(
                permissions: 0o755,
                owner: "mock",
                group: "mock",
                size: 0,
                modifiedAt: now,
                isDirectory: true
            ),
        ]
    }

    public func list(path: String) async throws -> [RemoteFileEntry] {
        let normalized = normalize(path)
        guard directoryExists(at: normalized) else {
            throw SFTPClientError.notFound(normalized)
        }

        let prefix = normalized == "/" ? "/" : normalized + "/"
        var names = Set<String>()

        for fullPath in files.keys {
            guard fullPath.hasPrefix(prefix) else { continue }
            let suffix = String(fullPath.dropFirst(prefix.count))
            guard !suffix.isEmpty else { continue }
            guard let firstComponent = suffix.split(separator: "/").first else { continue }
            names.insert(String(firstComponent))
        }

        for fullPath in directories.keys where fullPath != normalized {
            guard fullPath.hasPrefix(prefix) else { continue }
            let suffix = String(fullPath.dropFirst(prefix.count))
            guard !suffix.isEmpty else { continue }
            guard let firstComponent = suffix.split(separator: "/").first else { continue }
            names.insert(String(firstComponent))
        }

        return names.sorted().map { name in
            let fullPath = prefix + name
            if let directory = directories[fullPath] {
                return RemoteFileEntry(
                    name: name,
                    path: fullPath,
                    size: directory.size,
                    permissions: directory.permissions,
                    owner: directory.owner,
                    group: directory.group,
                    isDirectory: true,
                    modifiedAt: directory.modifiedAt
                )
            }

            if let file = files[fullPath] {
                return RemoteFileEntry(
                    name: name,
                    path: fullPath,
                    size: Int64(file.data.count),
                    permissions: file.attributes.permissions,
                    owner: file.attributes.owner,
                    group: file.attributes.group,
                    isDirectory: false,
                    modifiedAt: file.attributes.modifiedAt
                )
            }

            return RemoteFileEntry(name: name, path: fullPath, size: 0, isDirectory: true)
        }
    }

    public func download(path: String) async throws -> Data {
        try await download(path: path, progress: nil)
    }

    public func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        let key = normalize(path)
        guard let file = files[key] else {
            throw SFTPClientError.notFound(key)
        }

        let total = Int64(file.data.count)
        progress?(.init(bytesTransferred: 0, totalBytes: total))
        progress?(.init(bytesTransferred: total, totalBytes: total))
        return file.data
    }

    public func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws {
        let key = normalize(path)
        guard let file = files[key] else {
            throw SFTPClientError.notFound(key)
        }

        let total = Int64(file.data.count)
        progress?(.init(bytesTransferred: 0, totalBytes: total))
        try FileManager.default.createDirectory(
            at: localFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.data.write(to: localFileURL, options: .atomic)
        progress?(.init(bytesTransferred: total, totalBytes: total))
    }

    public func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String {
        _ = timeout
        let parsed = try parseTailCommand(command)
        return try renderTailOutput(path: parsed.path, lineCount: parsed.lineCount)
    }

    public func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> {
        let parsed = try parseTailCommand(command)
        guard parsed.follow else {
            let output = try renderTailOutput(path: parsed.path, lineCount: parsed.lineCount)
            return AsyncThrowingStream { continuation in
                continuation.yield(output)
                continuation.finish()
            }
        }

        let path = parsed.path
        let lineCount = parsed.lineCount
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lastOutput = try self.renderTailOutput(path: path, lineCount: lineCount)
                    continuation.yield(lastOutput)

                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(150))
                        let latest = try self.renderTailOutput(path: path, lineCount: lineCount)
                        guard latest != lastOutput else { continue }

                        if latest.hasPrefix(lastOutput) {
                            continuation.yield(String(latest.dropFirst(lastOutput.count)))
                        } else {
                            continuation.yield(latest)
                        }
                        lastOutput = latest
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func upload(data: Data, to path: String) async throws {
        try await upload(data: data, to: path, progress: nil)
    }

    public func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws {
        let destination = normalize(path)
        guard destination != "/" else {
            throw SFTPClientError.invalidPath(destination)
        }

        ensureParentDirectories(for: destination)
        let total = Int64(data.count)
        progress?(.init(bytesTransferred: 0, totalBytes: total))
        files[destination] = StoredFile(
            data: data,
            attributes: RemoteFileAttributes(
                permissions: 0o644,
                owner: "mock",
                group: "mock",
                size: total,
                modifiedAt: Date(),
                isDirectory: false
            )
        )
        updateParentModifiedTimes(for: destination)
        progress?(.init(bytesTransferred: total, totalBytes: total))
    }

    public func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws {
        let data = try Data(contentsOf: fileURL)
        try await upload(data: data, to: path, progress: progress)
    }

    public func rename(from: String, to: String) async throws {
        try await move(from: from, to: to)
    }

    public func move(from: String, to: String) async throws {
        let source = normalize(from)
        let destination = normalize(to)
        guard source != destination else { return }
        guard source != "/" else { throw SFTPClientError.invalidPath(source) }

        if var file = files.removeValue(forKey: source) {
            ensureParentDirectories(for: destination)
            file.attributes.modifiedAt = Date()
            files[destination] = file
            updateParentModifiedTimes(for: destination)
            return
        }

        guard let directoryAttributes = directories[source] else {
            throw SFTPClientError.notFound(source)
        }

        ensureParentDirectories(for: destination)

        let sourcePrefix = source + "/"
        let destinationPrefix = destination + "/"
        var movedDirectories: [(String, RemoteFileAttributes)] = []
        var movedFiles: [(String, StoredFile)] = []

        for (path, attributes) in directories where path.hasPrefix(sourcePrefix) {
            let suffix = String(path.dropFirst(sourcePrefix.count))
            movedDirectories.append((destinationPrefix + suffix, attributes))
        }
        for (path, file) in files where path.hasPrefix(sourcePrefix) {
            let suffix = String(path.dropFirst(sourcePrefix.count))
            movedFiles.append((destinationPrefix + suffix, file))
        }

        directories[source] = nil
        directories[destination] = RemoteFileAttributes(
            permissions: directoryAttributes.permissions,
            owner: directoryAttributes.owner,
            group: directoryAttributes.group,
            size: 0,
            modifiedAt: Date(),
            isDirectory: true
        )

        let nestedDirectoryPathsToRemove = directories.keys.filter { $0.hasPrefix(sourcePrefix) }
        for path in nestedDirectoryPathsToRemove {
            directories[path] = nil
        }
        let nestedFilePathsToRemove = files.keys.filter { $0.hasPrefix(sourcePrefix) }
        for path in nestedFilePathsToRemove {
            files[path] = nil
        }

        for (path, attributes) in movedDirectories {
            directories[path] = RemoteFileAttributes(
                permissions: attributes.permissions,
                owner: attributes.owner,
                group: attributes.group,
                size: 0,
                modifiedAt: Date(),
                isDirectory: true
            )
        }
        for (path, file) in movedFiles {
            files[path] = StoredFile(
                data: file.data,
                attributes: RemoteFileAttributes(
                    permissions: file.attributes.permissions,
                    owner: file.attributes.owner,
                    group: file.attributes.group,
                    size: Int64(file.data.count),
                    modifiedAt: Date(),
                    isDirectory: false
                )
            )
        }
        updateParentModifiedTimes(for: destination)
    }

    public func copy(from: String, to: String) async throws {
        let source = normalize(from)
        let destination = normalize(to)

        if let file = files[source] {
            try await upload(data: file.data, to: destination, progress: nil)
            return
        }

        guard let sourceDirectory = directories[source] else {
            throw SFTPClientError.notFound(source)
        }

        ensureParentDirectories(for: destination)
        directories[destination] = RemoteFileAttributes(
            permissions: sourceDirectory.permissions,
            owner: sourceDirectory.owner,
            group: sourceDirectory.group,
            size: 0,
            modifiedAt: Date(),
            isDirectory: true
        )

        let sourcePrefix = source + "/"
        let destinationPrefix = destination + "/"
        let nestedDirectoriesToCopy = directories.compactMap { path, attributes -> (String, RemoteFileAttributes)? in
            guard path.hasPrefix(sourcePrefix) else { return nil }
            let suffix = String(path.dropFirst(sourcePrefix.count))
            return (destinationPrefix + suffix, attributes)
        }
        for (copiedPath, attributes) in nestedDirectoriesToCopy {
            directories[copiedPath] = RemoteFileAttributes(
                permissions: attributes.permissions,
                owner: attributes.owner,
                group: attributes.group,
                size: 0,
                modifiedAt: Date(),
                isDirectory: true
            )
        }

        let nestedFilesToCopy = files.compactMap { path, file -> (String, StoredFile)? in
            guard path.hasPrefix(sourcePrefix) else { return nil }
            let suffix = String(path.dropFirst(sourcePrefix.count))
            return (destinationPrefix + suffix, file)
        }
        for (copiedPath, file) in nestedFilesToCopy {
            files[copiedPath] = StoredFile(
                data: file.data,
                attributes: RemoteFileAttributes(
                    permissions: file.attributes.permissions,
                    owner: file.attributes.owner,
                    group: file.attributes.group,
                    size: Int64(file.data.count),
                    modifiedAt: Date(),
                    isDirectory: false
                )
            )
        }
    }

    public func mkdir(path: String) async throws {
        let directory = normalize(path)
        ensureParentDirectories(for: directory)
        if directories[directory] == nil {
            directories[directory] = RemoteFileAttributes(
                permissions: 0o755,
                owner: "mock",
                group: "mock",
                size: 0,
                modifiedAt: Date(),
                isDirectory: true
            )
        }
        updateParentModifiedTimes(for: directory)
    }

    public func remove(path: String) async throws {
        let target = normalize(path)
        guard target != "/" else {
            throw SFTPClientError.invalidPath(target)
        }

        if files.removeValue(forKey: target) != nil {
            updateParentModifiedTimes(for: target)
            return
        }

        guard directories[target] != nil else {
            throw SFTPClientError.notFound(target)
        }

        directories[target] = nil
        let prefix = target + "/"
        let filePathsToRemove = files.keys.filter { $0.hasPrefix(prefix) }
        for path in filePathsToRemove {
            files[path] = nil
        }
        let directoryPathsToRemove = directories.keys.filter { $0.hasPrefix(prefix) }
        for path in directoryPathsToRemove {
            directories[path] = nil
        }
        updateParentModifiedTimes(for: target)
    }

    public func stat(path: String) async throws -> RemoteFileAttributes {
        let target = normalize(path)
        if let file = files[target] {
            return file.attributes
        }
        if let directory = directories[target] {
            return directory
        }
        throw SFTPClientError.notFound(target)
    }

    public func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
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
        throw SFTPClientError.notFound(target)
    }

    private func normalize(_ path: String) -> String {
        guard path != "/" else { return path }
        let leading = path.hasPrefix("/") ? path : "/\(path)"
        return leading.replacingOccurrences(of: "//", with: "/")
    }

    private func directoryExists(at path: String) -> Bool {
        if directories[path] != nil {
            return true
        }
        let prefix = path == "/" ? "/" : path + "/"
        if files.keys.contains(where: { $0.hasPrefix(prefix) }) {
            return true
        }
        return directories.keys.contains(where: { $0.hasPrefix(prefix) })
    }

    private func renderTailOutput(path: String, lineCount: Int) throws -> String {
        guard let file = files[path] else {
            throw SFTPClientError.notFound(path)
        }

        let content = String(decoding: file.data, as: UTF8.self)
        let normalizedNewlines = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false)
        let tailLines = lines.suffix(lineCount)
        return tailLines.joined(separator: "\n")
    }

    private func parseTailCommand(_ command: String) throws -> (lineCount: Int, follow: Bool, path: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tailRange = trimmed.range(of: "tail -n ") else {
            throw SFTPClientError.unsupportedOperation("remote-shell-command")
        }

        let suffix = trimmed[tailRange.upperBound...]
        guard let spaceIndex = suffix.firstIndex(of: " ") else {
            throw SFTPClientError.unsupportedOperation("remote-shell-command")
        }

        let lineCountText = suffix[..<spaceIndex]
        guard let lineCount = Int(lineCountText), lineCount > 0 else {
            throw SFTPClientError.unsupportedOperation("remote-shell-command")
        }

        let follow = trimmed.contains(" -f ")
        guard let pathMarkerRange = trimmed.range(of: " ", options: .backwards) else {
            throw SFTPClientError.unsupportedOperation("remote-shell-command")
        }

        let rawPath = String(trimmed[pathMarkerRange.upperBound...])
        let normalizedPath = normalize(unquoteShellArgument(rawPath))
        return (lineCount, follow, normalizedPath)
    }

    private func unquoteShellArgument(_ value: String) -> String {
        guard value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 else {
            return value
        }

        let inner = String(value.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }

    private func ensureParentDirectories(for path: String) {
        let normalized = normalize(path)
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        var cursor = ""
        for component in components.dropLast() {
            cursor += "/\(component)"
            if directories[cursor] == nil {
                directories[cursor] = RemoteFileAttributes(
                    permissions: 0o755,
                    owner: "mock",
                    group: "mock",
                    size: 0,
                    modifiedAt: Date(),
                    isDirectory: true
                )
            }
        }

        if directories["/"] == nil {
            directories["/"] = RemoteFileAttributes(
                permissions: 0o755,
                owner: "mock",
                group: "mock",
                size: 0,
                modifiedAt: Date(),
                isDirectory: true
            )
        }
    }

    private func updateParentModifiedTimes(for path: String) {
        let normalized = normalize(path)
        var parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        if parent.isEmpty {
            parent = "/"
        }

        while true {
            if var directory = directories[parent] {
                directory.modifiedAt = Date()
                directories[parent] = directory
            }

            if parent == "/" { break }
            let nextParent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            parent = nextParent.isEmpty ? "/" : nextParent
        }
    }
}
