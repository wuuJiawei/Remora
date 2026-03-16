import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

struct RemoteLogViewerViewModelTests {
    @Test
    @MainActor
    func followModeRefreshesWhenRemoteLogChanges() async throws {
        let client = MockSFTPClient()
        try await client.upload(
            data: Data("boot\nready".utf8),
            to: "/logs/app.log"
        )
        let fileTransfer = FileTransferViewModel(
            sftpClient: client,
            remoteDirectoryPath: "/logs"
        )
        let viewModel = RemoteLogViewerViewModel(
            path: "/logs/app.log",
            fileTransfer: fileTransfer,
            followRefreshInterval: .milliseconds(100)
        )

        await viewModel.load()
        for _ in 0 ..< 20 {
            if viewModel.text == "boot\nready" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(viewModel.text == "boot\nready")

        try await client.upload(
            data: Data("boot\nready\nworker-started".utf8),
            to: "/logs/app.log"
        )

        for _ in 0 ..< 20 {
            if viewModel.text.contains("worker-started") {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(viewModel.text.contains("worker-started"))
        viewModel.stop()
    }
}
