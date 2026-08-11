import AppKit
import Foundation
import Testing
@testable import RemoraTerminal

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
        view.flushPendingOutput()
        view.selectAll()

        NSPasteboard.general.clearContents()
        view.performTerminalAction(.copy)

        #expect(NSPasteboard.general.string(forType: .string)?.contains("alpha beta") == true)
    }

    @Test
    func outputWithoutTrailingNewlineKeepsPromptOnSameLine() {
        let view = TerminalView(rows: 6, columns: 80)
        view.feed(data: Data("{\"code\":404}PROMPT> ".utf8))
        view.flushPendingOutput()
        view.selectAll()

        NSPasteboard.general.clearContents()
        view.performTerminalAction(.copy)

        let copied = NSPasteboard.general.string(forType: .string)?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        #expect(copied?.contains("{\"code\":404}PROMPT> ") == true)
    }

    @Test
    func outputWithTrailingNewlineStartsPromptOnNextLine() {
        let view = TerminalView(rows: 6, columns: 80)
        view.feed(data: Data("ok\r\nPROMPT> ".utf8))
        view.flushPendingOutput()
        view.selectAll()

        NSPasteboard.general.clearContents()
        view.performTerminalAction(.copy)

        let copied = NSPasteboard.general.string(forType: .string)?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        #expect(copied?.contains("ok\nPROMPT> ") == true)
    }

    @Test
    func outputCoalescingAppliesBoundedBackpressure() {
        let view = TerminalView(rows: 6, columns: 40)
        view.renderingConfiguration = TerminalRenderingConfiguration(
            coalescesOutput: true,
            outputFlushInterval: 60,
            maxPendingOutputBytes: 3,
            maxOutputBytesPerFlush: 2,
            automaticallyEnableMetal: false
        )

        view.feed(data: Data("abcd".utf8))

        #expect(view.pendingOutputByteCount == 3)
        #expect(view.droppedOutputByteCount == 1)

        view.flushPendingOutput()
        #expect(view.pendingOutputByteCount == 0)

        view.renderingConfiguration = TerminalRenderingConfiguration(
            coalescesOutput: false,
            automaticallyEnableMetal: false
        )
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
    func rightClickKeepsContextMenuWhenCopyOnSelectIsDisabled() throws {
        let view = TerminalView(rows: 6, columns: 40)
        view.copyOnSelect = false

        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseUp,
                location: .init(x: 10, y: 10),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        let menu = view.menu(for: event)
        #expect(menu != nil)
        #expect(menu?.items.contains(where: { $0.action == #selector(TerminalView.paste(_:)) }) == true)
    }

    @Test
    func rightClickTriggersPasteWhenCopyOnSelectIsEnabled() throws {
        let view = TerminalView(rows: 6, columns: 40)
        view.copyOnSelect = true

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("copied text", forType: .string)

        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseUp,
                location: .init(x: 10, y: 10),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        let menu = view.menu(for: event)
        #expect(menu == nil)
    }

    @Test
    func contextMenuShortcutMappingMatchesTerminalCommands() {
        #expect(TerminalView.shortcut(for: .copy) == TerminalActionShortcut(keyEquivalent: "c", modifierFlags: [.command]))
        #expect(TerminalView.shortcut(for: .paste) == TerminalActionShortcut(keyEquivalent: "v", modifierFlags: [.command]))
        #expect(TerminalView.shortcut(for: .selectAll) == TerminalActionShortcut(keyEquivalent: "a", modifierFlags: [.command]))
        #expect(TerminalView.shortcut(for: .clearScreen) == TerminalActionShortcut(keyEquivalent: "k", modifierFlags: [.command]))
    }

    @Test
    func mouseDownMakesTerminalFirstResponder() throws {
        let view = TerminalView(rows: 6, columns: 40)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.frame = host.bounds
        host.addSubview(view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeFirstResponder(host)

        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 160, y: 120),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        view.mouseDown(with: event)

        #expect(window.firstResponder === view)
    }

    @Test
    func terminalMouseDownDoesNotChangeOtherWindowFirstResponder() throws {
        let terminalView = TerminalView(rows: 6, columns: 40)
        let terminalHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        terminalView.frame = terminalHost.bounds
        terminalHost.addSubview(terminalView)

        let terminalWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        terminalWindow.contentView = terminalHost

        let editorResponder = FirstResponderProbeView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        editorWindow.contentView = editorResponder
        editorWindow.makeFirstResponder(editorResponder)

        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 160, y: 120),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: terminalWindow.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        terminalView.mouseDown(with: event)

        #expect(terminalWindow.firstResponder === terminalView)
        #expect(editorWindow.firstResponder === editorResponder)
    }

    @Test
    func selectionAutoscrollMovesDownWhenPointerDropsBelowViewport() {
        let delta = TerminalSelectionAutoscroll.delta(
            for: -18,
            viewHeight: 240,
            visibleRows: 24
        )

        #expect(delta > 0)
    }

    @Test
    func selectionAutoscrollMovesUpWhenPointerRisesAboveViewport() {
        let delta = TerminalSelectionAutoscroll.delta(
            for: 258,
            viewHeight: 240,
            visibleRows: 24
        )

        #expect(delta < 0)
    }

    @Test
    func selectionAutoscrollUsesFasterVelocityFurtherOutsideViewport() {
        let nearEdge = TerminalSelectionAutoscroll.delta(
            for: -6,
            viewHeight: 240,
            visibleRows: 24
        )
        let farEdge = TerminalSelectionAutoscroll.delta(
            for: -140,
            viewHeight: 240,
            visibleRows: 24
        )

        #expect(nearEdge == 1)
        #expect(farEdge == 24)
        #expect(farEdge > nearEdge)
    }
}

private final class FirstResponderProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
