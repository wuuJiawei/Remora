import AppKit
import Foundation
import Testing
import RemoraTerminal

@MainActor
struct TerminalViewTests {
    @Test
    func contextMenuOmitsCopyWithoutSelection() {
        let items = TerminalView.contextMenuItems(
            hasSelection: false,
            canPaste: false,
            canClearScreen: true
        )

        #expect(items.map(\.action) == [.paste, .selectAll, .clearScreen])
        #expect(items.first?.isEnabled == false)
    }

    @Test
    func contextMenuIncludesCopyWhenSelectionExists() {
        let items = TerminalView.contextMenuItems(
            hasSelection: true,
            canPaste: true,
            canClearScreen: true
        )

        #expect(items.map(\.action) == [.copy, .paste, .selectAll, .clearScreen])
        #expect(items.map(\.isEnabled) == [true, true, true, true])
    }

    @Test
    func copyActionWritesSelectedTextToPasteboard() {
        let view = TerminalView(rows: 6, columns: 40)
        view.feed(data: Data("alpha beta\r\n".utf8))
        view.selectAll()

        NSPasteboard.general.clearContents()
        view.performTerminalAction(.copy)

        #expect(NSPasteboard.general.string(forType: .string)?.contains("alpha beta") == true)
    }

    @Test
    func clearScreenActionCallsHandler() {
        let view = TerminalView(rows: 6, columns: 40)
        var clearCalls = 0
        view.onClearScreen = {
            clearCalls += 1
        }

        view.performTerminalAction(.clearScreen)

        #expect(clearCalls == 1)
    }

    @Test
    func contextMenuShortcutMappingMatchesTerminalCommands() {
        #expect(TerminalView.shortcut(for: .copy) == TerminalActionShortcut(keyEquivalent: "c", modifierFlags: [.command]))
        #expect(TerminalView.shortcut(for: .paste) == TerminalActionShortcut(keyEquivalent: "v", modifierFlags: [.command]))
        #expect(TerminalView.shortcut(for: .selectAll) == TerminalActionShortcut(keyEquivalent: "a", modifierFlags: [.command]))
        #expect(TerminalView.shortcut(for: .clearScreen) == TerminalActionShortcut(keyEquivalent: "k", modifierFlags: [.command]))
    }
}
