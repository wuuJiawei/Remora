import Testing
@testable import RemoraApp

struct FileManagerContextMenuTests {
    @Test
    func downloadActionStaysEnabledForDirectories() {
        #expect(FileManagerContextMenuPolicy.isDownloadDisabled(isDirectory: false) == false)
        #expect(FileManagerContextMenuPolicy.isDownloadDisabled(isDirectory: true) == false)
    }

    @Test
    func batchDownloadIncludesSelectedDirectories() {
        let selectedPaths: Set<String> = ["/logs", "/README.txt"]

        #expect(FileManagerContextMenuPolicy.downloadablePaths(for: selectedPaths) == ["/README.txt", "/logs"])
        #expect(FileManagerContextMenuPolicy.isBatchDownloadDisabled(selectedPaths: selectedPaths) == false)
    }
}
