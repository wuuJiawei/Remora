import Foundation

public actor RemoteFileSystemOperations {
    private static let chunkSize = 64 * 1_024

    private let fileSystem: any RemoteFileSystemProtocol

    public init(fileSystem: any RemoteFileSystemProtocol) {
        self.fileSystem = fileSystem
    }

    public func list(path: String) async throws -> [RemoteFileEntry] {
        try await fileSystem.listDirectory(path: path)
    }

    public func attributes(path: String, followSymbolicLinks: Bool = true) async throws -> RemoteFileAttributes {
        try await fileSystem.attributes(path: path, followSymbolicLinks: followSymbolicLinks)
    }

    public func createEmptyFile(path: String) async throws {
        let handle = try await fileSystem.openFile(
            path: path,
            options: [.write, .create, .truncate],
            attributes: nil
        )
        await handle.close()
    }

    public func createDirectory(path: String) async throws {
        try await fileSystem.createDirectory(path: path, attributes: nil)
    }

    public func rename(from source: String, to destination: String, overwrite: Bool = false) async throws {
        try await fileSystem.rename(from: source, to: destination, overwrite: overwrite)
    }

    public func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        try await fileSystem.setAttributes(path: path, attributes: attributes)
    }

    public func removeRecursively(path: String) async throws {
        let attributes = try await fileSystem.attributes(path: path, followSymbolicLinks: false)
        if attributes.isDirectory && !attributes.isSymbolicLink {
            let entries = try await fileSystem.listDirectory(path: path)
            for entry in entries {
                try Task.checkCancellation()
                try await removeRecursively(path: entry.path)
            }
            try await fileSystem.removeDirectory(path: path)
        } else {
            try await fileSystem.removeFile(path: path)
        }
    }

    public func copyRecursively(from source: String, to destination: String) async throws {
        let attributes = try await fileSystem.attributes(path: source, followSymbolicLinks: false)
        if attributes.isSymbolicLink {
            let target = try await fileSystem.readSymbolicLink(path: source)
            try await fileSystem.createSymbolicLink(path: destination, target: target)
            return
        }
        if attributes.isDirectory {
            try await fileSystem.createDirectory(path: destination, attributes: attributes)
            let entries = try await fileSystem.listDirectory(path: source)
            for entry in entries {
                try Task.checkCancellation()
                try await copyRecursively(
                    from: entry.path,
                    to: Self.join(parent: destination, name: entry.name)
                )
            }
            return
        }
        try await copyFileAtomically(from: source, to: destination, attributes: attributes)
    }

    public func download(
        path: String,
        to localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        let attributes = try? await fileSystem.attributes(path: path, followSymbolicLinks: true)
        let expectedSize = attributes?.size
        progress?(.init(bytesTransferred: 0, totalBytes: expectedSize))

        let directory = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".remora-download-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let localHandle = try FileHandle(forWritingTo: temporaryURL)
        let remoteHandle = try await fileSystem.openFile(path: path, options: .read, attributes: nil)
        var transferred: Int64 = 0

        do {
            while true {
                try Task.checkCancellation()
                let chunk = try await remoteHandle.read(maximumBytes: Self.chunkSize)
                if chunk.isEmpty { break }
                try localHandle.write(contentsOf: chunk)
                transferred += Int64(chunk.count)
                progress?(.init(bytesTransferred: transferred, totalBytes: expectedSize))
            }
            try localHandle.close()
            await remoteHandle.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            progress?(.init(bytesTransferred: transferred, totalBytes: expectedSize ?? transferred))
        } catch {
            try? localHandle.close()
            await remoteHandle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    public func upload(
        data: Data,
        to path: String,
        progress: TransferProgressHandler? = nil
    ) async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        try await upload(fileURL: temporaryURL, to: path, progress: progress)
    }

    public func upload(
        fileURL: URL,
        to path: String,
        progress: TransferProgressHandler?
    ) async throws {
        let totalSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        progress?(.init(bytesTransferred: 0, totalBytes: totalSize))
        let temporaryPath = Self.temporarySiblingPath(for: path)
        let remoteHandle = try await fileSystem.openFile(
            path: temporaryPath,
            options: [.write, .create, .truncate, .exclusive],
            attributes: nil
        )
        let localHandle = try FileHandle(forReadingFrom: fileURL)
        var transferred: Int64 = 0

        do {
            while true {
                try Task.checkCancellation()
                let chunk = try localHandle.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try await writeAll(chunk, to: remoteHandle)
                transferred += Int64(chunk.count)
                progress?(.init(bytesTransferred: transferred, totalBytes: totalSize))
            }
            try localHandle.close()
            await remoteHandle.close()
            try await fileSystem.rename(from: temporaryPath, to: path, overwrite: true)
            progress?(.init(bytesTransferred: transferred, totalBytes: totalSize ?? transferred))
        } catch {
            try? localHandle.close()
            await remoteHandle.close()
            try? await fileSystem.removeFile(path: temporaryPath)
            throw error
        }
    }

    private func copyFileAtomically(
        from source: String,
        to destination: String,
        attributes: RemoteFileAttributes
    ) async throws {
        let temporaryPath = Self.temporarySiblingPath(for: destination)
        let sourceHandle = try await fileSystem.openFile(path: source, options: .read, attributes: nil)
        let destinationHandle = try await fileSystem.openFile(
            path: temporaryPath,
            options: [.write, .create, .truncate, .exclusive],
            attributes: attributes
        )
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try await sourceHandle.read(maximumBytes: Self.chunkSize)
                if chunk.isEmpty { break }
                try await writeAll(chunk, to: destinationHandle)
            }
            await sourceHandle.close()
            await destinationHandle.close()
            try await fileSystem.rename(from: temporaryPath, to: destination, overwrite: true)
            try await fileSystem.setAttributes(path: destination, attributes: attributes)
        } catch {
            await sourceHandle.close()
            await destinationHandle.close()
            try? await fileSystem.removeFile(path: temporaryPath)
            throw error
        }
    }

    private func writeAll(_ data: Data, to handle: any RemoteFileHandleProtocol) async throws {
        var offset = 0
        while offset < data.count {
            let written = try await handle.write(Data(data[offset...]))
            guard written > 0 else {
                throw RemoteFileSystemOperationError(status: .connectionLost)
            }
            offset += written
        }
    }

    private static func temporarySiblingPath(for path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let directory = parent.isEmpty ? "/" : parent
        return join(parent: directory, name: ".remora-upload-\(UUID().uuidString)")
    }

    private static func join(parent: String, name: String) -> String {
        parent == "/" ? "/\(name)" : parent + "/" + name
    }
}
