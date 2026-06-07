import Testing
import Foundation
import RemoraCore
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

    @Test
    func detailCopyPathFallsBackToCurrentDirectoryWhenContextMenuOpensOnBlankArea() {
        #expect(
            FileManagerContextCopyPathResolver.detailTargetPath(
                currentPath: "/var/www",
                clickedEntryPath: nil
            ) == "/var/www"
        )
    }

    @Test
    func detailCopyPathUsesClickedEntryWhenContextMenuOpensOnRow() {
        let file = RemoteFileEntry(
            name: "README.md",
            path: "/var/www/README.md",
            size: 128,
            isDirectory: false,
            modifiedAt: Date()
        )

        #expect(
            FileManagerContextCopyPathResolver.detailTargetPath(
                currentPath: "/var/www",
                clickedEntryPath: file.path
            ) == "/var/www/README.md"
        )
    }

    @Test
    func sidebarCopyPathResolvesQuickPathAndRoot() {
        #expect(FileManagerContextCopyPathResolver.sidebarTargetPath(clickedItemPath: "/") == "/")
        #expect(FileManagerContextCopyPathResolver.sidebarTargetPath(clickedItemPath: "/srv/app") == "/srv/app")
        #expect(FileManagerContextCopyPathResolver.sidebarTargetPath(clickedItemPath: nil) == nil)
    }
}
