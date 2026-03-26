import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

@MainActor
struct FileTransferDiagnosticsTests {
    @Test
    func failedTransfersIncludeDiagnosticLogPath() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-transfer-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vm = FileTransferViewModel(
            sftpClient: FailingDownloadSFTPClient(),
            localDirectoryURL: tempRoot,
            remoteDirectoryPath: "/",
            maxConcurrentTransfers: 1
        )

        await vm.refreshRemoteEntries()
        guard let readme = vm.remoteEntries.first(where: { $0.path == "/README.txt" }) else {
            Issue.record("Remote README not found.")
            return
        }

        vm.enqueueDownload(remoteEntry: readme)
        try await waitUntil(timeoutLoops: 40, intervalMS: 50) {
            vm.transferQueue.contains { item in
                item.direction == .download && item.status == .failed
            }
        }

        guard let failed = vm.transferQueue.first(where: { item in
            item.direction == .download && item.status == .failed
        }) else {
            Issue.record("Expected failed transfer.")
            return
        }

        #expect(failed.message?.contains(FileTransferDiagnostics.displayPath) == true)
    }

    private func waitUntil(timeoutLoops: Int, intervalMS: UInt64, condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0 ..< timeoutLoops {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(intervalMS))
        }
        throw NSError(domain: "FileTransferDiagnosticsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeout waiting condition"])
    }
}

private actor FailingDownloadSFTPClient: SFTPClientProtocol {
    private let base = MockSFTPClient()

    func list(path: String) async throws -> [RemoteFileEntry] { try await base.list(path: path) }
    func download(path: String) async throws -> Data { throw NSError(domain: "Remora.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection failed"]) }
    func download(path: String, progress: TransferProgressHandler?) async throws -> Data { throw NSError(domain: "Remora.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection failed"]) }
    func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws { throw NSError(domain: "Remora.Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection failed"]) }
    func executeRemoteShellCommand(_ command: String, timeout: TimeInterval?) async throws -> String { try await base.executeRemoteShellCommand(command, timeout: timeout) }
    func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> { try await base.streamRemoteShellCommand(command) }
    func upload(data: Data, to path: String) async throws { try await base.upload(data: data, to: path) }
    func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws { try await base.upload(data: data, to: path, progress: progress) }
    func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws { try await base.upload(fileURL: fileURL, to: path, progress: progress) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func copy(from: String, to: String) async throws { try await base.copy(from: from, to: to) }
    func mkdir(path: String) async throws { try await base.mkdir(path: path) }
    func remove(path: String) async throws { try await base.remove(path: path) }
    func stat(path: String) async throws -> RemoteFileAttributes { try await base.stat(path: path) }
    func setAttributes(path: String, attributes: RemoteFileAttributes) async throws { try await base.setAttributes(path: path, attributes: attributes) }
}
