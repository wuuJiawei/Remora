import Foundation
import Testing
@testable import RemoraCore

private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [TransferProgressSnapshot] = []

    func append(_ snapshot: TransferProgressSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    func values() -> [TransferProgressSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
}

struct MockSFTPClientTests {
    @Test
    func uploadRenameDownloadRemoveRoundTrip() async throws {
        let client = MockSFTPClient()

        try await client.upload(data: Data("hello".utf8), to: "/tmp/hello.txt")
        try await client.rename(from: "/tmp/hello.txt", to: "/tmp/world.txt")

        let payload = try await client.download(path: "/tmp/world.txt")
        #expect(String(decoding: payload, as: UTF8.self) == "hello")

        try await client.remove(path: "/tmp/world.txt")
        let list = try await client.list(path: "/tmp")
        #expect(list.first(where: { $0.name == "world.txt" }) == nil)
    }

    @Test
    func uploadAndDownloadProgressAreReported() async throws {
        let client = MockSFTPClient()
        let payload = Data("progress-case".utf8)
        let uploadProgress = SnapshotCollector()
        let downloadProgress = SnapshotCollector()

        try await client.upload(
            data: payload,
            to: "/tmp/progress.txt",
            progress: { snapshot in
                uploadProgress.append(snapshot)
            }
        )

        let downloaded = try await client.download(
            path: "/tmp/progress.txt",
            progress: { snapshot in
                downloadProgress.append(snapshot)
            }
        )
        let uploadValues = uploadProgress.values()
        let downloadValues = downloadProgress.values()

        #expect(downloaded == payload)
        #expect(uploadValues.count >= 2)
        #expect(downloadValues.count >= 2)
        #expect(uploadValues.last?.bytesTransferred == Int64(payload.count))
        #expect(downloadValues.last?.bytesTransferred == Int64(payload.count))
        #expect(uploadValues.last?.fractionCompleted == 1)
        #expect(downloadValues.last?.fractionCompleted == 1)
    }

    @Test
    func downloadToLocalFileWritesPayloadWithoutReturningData() async throws {
        let client = MockSFTPClient()
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-mock-sftp-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("README.txt")
        try await client.download(path: "/README.txt", to: destination, progress: nil)

        let payload = try Data(contentsOf: destination)
        #expect(String(decoding: payload, as: UTF8.self) == "Remora mock SFTP")
    }

    @Test
    func statAndSetAttributesWorkForFiles() async throws {
        let client = MockSFTPClient()
        var attrs = try await client.stat(path: "/README.txt")
        #expect(attrs.isDirectory == false)
        #expect(attrs.permissions == 0o644)

        attrs.permissions = 0o600
        attrs.owner = "tester"
        try await client.setAttributes(path: "/README.txt", attributes: attrs)

        let updated = try await client.stat(path: "/README.txt")
        #expect(updated.permissions == 0o600)
        #expect(updated.owner == "tester")
    }

    @Test
    func copyAndMoveDirectoryRecursively() async throws {
        let client = MockSFTPClient()

        try await client.copy(from: "/logs", to: "/logs-copy")
        let copiedEntries = try await client.list(path: "/logs-copy")
        #expect(copiedEntries.first(where: { $0.name == "app.log" }) != nil)

        try await client.move(from: "/logs-copy", to: "/archive/logs")
        let movedEntries = try await client.list(path: "/archive/logs")
        #expect(movedEntries.first(where: { $0.name == "app.log" }) != nil)

        let rootEntries = try await client.list(path: "/")
        #expect(rootEntries.first(where: { $0.name == "logs-copy" }) == nil)
    }

}
