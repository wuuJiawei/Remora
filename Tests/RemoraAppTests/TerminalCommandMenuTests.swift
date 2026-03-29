import AppKit
import Testing
@testable import RemoraApp

struct TerminalCommandMenuTests {
    @Test
    func terminalCommandsUseExpectedSelectorsAndDefaults() {
        #expect(AppShortcutCommand.terminalCopy.defaultShortcut?.displayText == "⌘C")
        #expect(AppShortcutCommand.terminalPaste.defaultShortcut?.displayText == "⌘V")
        #expect(AppShortcutCommand.terminalClearScreen.defaultShortcut?.displayText == "⌘K")
        #expect(AppShortcutCommand.terminalCopy.selector == #selector(NSText.copy(_:)))
        #expect(AppShortcutCommand.terminalPaste.selector == #selector(NSText.paste(_:)))
        #expect(AppShortcutCommand.terminalClearScreen.selector != nil)
        #expect(AppShortcutCommand.terminalCopy.notificationName == nil)
    }
}
