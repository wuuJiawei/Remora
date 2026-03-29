import AppKit
import Foundation
import Testing
@testable import RemoraApp

@MainActor
struct AppKeyboardShortcutStoreTests {
    @Test
    func usesExpectedDefaultShortcuts() {
        let store = makeStore()

        #expect(store.shortcut(for: .openSettings)?.displayText == "⌘,")
        #expect(store.shortcut(for: .toggleSSHSidebar)?.displayText == "⌘B")
        #expect(store.shortcut(for: .newSSHConnection)?.displayText == "⌘⇧N")
        #expect(store.shortcut(for: .importConnections)?.displayText == "⌘I")
        #expect(store.shortcut(for: .exportConnections)?.displayText == "⌘E")
        #expect(store.shortcut(for: .terminalCopy)?.displayText == "⌘C")
        #expect(store.shortcut(for: .terminalPaste)?.displayText == "⌘V")
        #expect(store.shortcut(for: .terminalClearScreen)?.displayText == "⌘K")
    }

    @Test
    func persistsCustomAndUnboundShortcuts() {
        let fileURL = makeStorageFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AppKeyboardShortcutStore(fileURL: fileURL)
        store.unbindShortcut(for: .importConnections)
        store.setShortcut(
            AppKeyboardShortcut(keyToken: "k", modifierFlags: [.command, .shift]),
            for: .exportConnections
        )

        let reloaded = AppKeyboardShortcutStore(fileURL: fileURL)
        #expect(reloaded.shortcut(for: .importConnections) == nil)
        #expect(reloaded.shortcut(for: .exportConnections)?.displayText == "⌘⇧K")
    }

    @Test
    func detectsConflictingShortcuts() {
        let store = makeStore()
        store.setShortcut(
            AppKeyboardShortcut(keyToken: "i", modifierFlags: [.command]),
            for: .exportConnections
        )

        #expect(store.conflicts.count == 1)
        let conflict = store.conflicts.first
        #expect(conflict?.shortcut.displayText == "⌘I")
        #expect(conflict?.commands.contains(.importConnections) == true)
        #expect(conflict?.commands.contains(.exportConnections) == true)
    }

    @Test
    func rejectsShortcutsWithoutPrimaryModifier() {
        let shortcut = AppKeyboardShortcut(keyToken: "a", modifierFlags: [.shift])
        #expect(!shortcut.isUsable)
    }

    private func makeStore() -> AppKeyboardShortcutStore {
        AppKeyboardShortcutStore(fileURL: makeStorageFileURL())
    }

    private func makeStorageFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-shortcuts-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("keyboard-shortcuts.json")
    }
}
