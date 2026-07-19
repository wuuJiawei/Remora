import AppKit
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

    @MainActor
    @Test
    func toolbarCopyPathUsesCurrentToolbarPath() {
        let toolbar = FileManagerWindowToolbar()
        var copiedPath: String?
        toolbar.onCopyCurrentPath = { path in
            copiedPath = path
        }

        toolbar.update(currentPath: "/srv/releases/app", canGoBack: true, canGoForward: false)
        toolbar.pathControl.onCopyPath?()

        #expect(copiedPath == "/srv/releases/app")
    }

    @MainActor
    @Test
    func terminalSyncToolbarItemSupportsLightAndDarkAppearances() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let toolbarController = FileManagerWindowToolbar()
            toolbarController.updateTerminalSync(isEnabled: true)

            let window = NSWindow()
            window.appearance = NSAppearance(named: appearanceName)
            window.toolbar = toolbarController.toolbar

            guard let item = toolbarController.toolbar.items.first(where: { $0.label == tr("Terminal Sync") }) else {
                Issue.record("Missing terminal sync toolbar item in \(appearanceName.rawValue) appearance.")
                continue
            }
            let enabledImage = item.image?.tiffRepresentation
            toolbarController.updateTerminalSync(isEnabled: false)
            let disabledImage = item.image?.tiffRepresentation

            #expect(enabledImage != nil)
            #expect(disabledImage != nil)
            #expect(enabledImage != disabledImage)

            var toggleCount = 0
            toolbarController.onTerminalSyncToggled = { toggleCount += 1 }
            guard let action = item.action else {
                Issue.record("Missing terminal sync toolbar action in \(appearanceName.rawValue) appearance.")
                continue
            }
            _ = NSApp.sendAction(action, to: item.target, from: item)
            #expect(toggleCount == 1)
        }
    }

    @Test
    func pasteTargetDirectoryUsesClickedDirectoryOtherwiseFallsBackToCurrentDirectory() {
        let directory = RemoteFileEntry(
            name: "logs",
            path: "/srv/app/logs",
            size: 0,
            isDirectory: true,
            modifiedAt: Date()
        )
        let file = RemoteFileEntry(
            name: "README.md",
            path: "/srv/app/README.md",
            size: 32,
            isDirectory: false,
            modifiedAt: Date()
        )

        #expect(FileManagerPasteTargetResolver.targetDirectory(currentPath: "/srv/app", clickedEntry: directory) == "/srv/app/logs")
        #expect(FileManagerPasteTargetResolver.targetDirectory(currentPath: "/srv/app", clickedEntry: file) == "/srv/app")
        #expect(FileManagerPasteTargetResolver.targetDirectory(currentPath: "/srv/app", clickedEntry: nil) == "/srv/app")
    }

    @Test
    func terminalTargetUsesDirectoryOrFileParentAndFallsBackToCurrentDirectory() {
        let directory = RemoteFileEntry(
            name: "logs",
            path: "/srv/app/logs",
            size: 0,
            isDirectory: true,
            modifiedAt: Date()
        )
        let file = RemoteFileEntry(
            name: "README.md",
            path: "/srv/app/README.md",
            size: 32,
            isDirectory: false,
            modifiedAt: Date()
        )

        #expect(FileManagerTerminalPathResolver.detailTargetDirectory(currentPath: "/srv/app", clickedEntry: directory) == "/srv/app/logs")
        #expect(FileManagerTerminalPathResolver.detailTargetDirectory(currentPath: "/srv/app", clickedEntry: file) == "/srv/app")
        #expect(FileManagerTerminalPathResolver.detailTargetDirectory(currentPath: "/srv/app", clickedEntry: nil) == "/srv/app")
        #expect(FileManagerTerminalPathResolver.sidebarTargetDirectory(clickedItemPath: "/srv/app") == "/srv/app")
        #expect(FileManagerTerminalPathResolver.sidebarTargetDirectory(clickedItemPath: nil) == nil)
    }
}
