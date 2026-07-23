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
            remoteFileSystem: MockRemoteFileSystem(
                configuration: .init(failingReadPaths: ["/README.txt"])
            ),
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
