import AppKit
import Foundation
import Testing
@testable import RemoraTerminal

@Suite(.serialized)
@MainActor
struct TerminalInputTests {
    private final class DataCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        var values: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test
    func terminalViewInsertTextSendsUTF8ForCJK() {
        let view = TerminalView(rows: 4, columns: 40)
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        view.insertText("中文输入", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(capture.values.count == 1)
        #expect(String(data: capture.values[0], encoding: .utf8) == "中文输入")
    }

    @Test
    func inputMapperCommandUsesApplicationCursorMode() {
        let mapper = TerminalInputMapper()

        mapper.applicationCursorKeysEnabled = false
        let normal = mapper.map(command: #selector(NSResponder.moveUp(_:)))
        #expect(normal == Data("\u{1B}[A".utf8))

        mapper.applicationCursorKeysEnabled = true
        let application = mapper.map(command: #selector(NSResponder.moveUp(_:)))
        #expect(application == Data("\u{1B}OA".utf8))
    }

    @Test
    func inputMapperUsesKittyCSIUForCommandSelectorsWhenEnabled() {
        let mapper = TerminalInputMapper()
        mapper.kittyKeyboardFlags = 1 // DISAMBIGUATE_ESCAPE_CODES

        let enter = mapper.map(command: #selector(NSResponder.insertNewline(_:)))
        let backspace = mapper.map(command: #selector(NSResponder.deleteBackward(_:)))
        let escape = mapper.map(command: #selector(NSResponder.cancelOperation(_:)))

        #expect(enter == Data("\u{1B}[13u".utf8))
        #expect(backspace == Data("\u{1B}[127u".utf8))
        #expect(escape == Data("\u{1B}[27u".utf8))
    }

    @Test
    func inputMapperKittyEncodesNavigationAndFunctionKeysLikeXterm() {
        let mapper = TerminalInputMapper()
        mapper.kittyKeyboardFlags = 1 // DISAMBIGUATE_ESCAPE_CODES

        let arrowUp = mapper.mapKittyKeyDown(event: keyEvent(keyCode: 126))
        let home = mapper.mapKittyKeyDown(event: keyEvent(keyCode: 115))
        let f1 = mapper.mapKittyKeyDown(event: keyEvent(keyCode: 122))
        let f5WithCtrl = mapper.mapKittyKeyDown(event: keyEvent(keyCode: 96, modifierFlags: .control))
        let insert = mapper.mapKittyKeyDown(event: keyEvent(keyCode: 114))

        #expect(arrowUp == Data("\u{1B}[A".utf8))
        #expect(home == Data("\u{1B}[H".utf8))
        #expect(f1 == Data("\u{1B}OP".utf8))
        #expect(f5WithCtrl == Data("\u{1B}[15;5~".utf8))
        #expect(insert == Data("\u{1B}[2~".utf8))
    }

    @Test
    func inputMapperKittyEncodesEventTypesForRepeatAndRelease() {
        let mapper = TerminalInputMapper()
        mapper.kittyKeyboardFlags = 3 // DISAMBIGUATE_ESCAPE_CODES | REPORT_EVENT_TYPES

        let repeatA = mapper.mapKittyKeyDown(event: keyEvent(characters: "a", charactersIgnoringModifiers: "a", isARepeat: true))
        let releaseA = mapper.mapKeyUp(event: keyEvent(type: .keyUp, characters: "a", charactersIgnoringModifiers: "a"))
        let deleteRelease = mapper.mapKeyUp(event: keyEvent(type: .keyUp, keyCode: 117))

        #expect(repeatA == Data("\u{1B}[97;1:2u".utf8))
        #expect(releaseA == Data("\u{1B}[97;1:3u".utf8))
        #expect(deleteRelease == Data("\u{1B}[3;1:3~".utf8))
    }

    @Test
    func inputMapperKittySupportsAlternateAndAssociatedTextFlags() {
        let mapper = TerminalInputMapper()
        mapper.kittyKeyboardFlags = 28 // REPORT_ALL_KEYS_AS_ESCAPE_CODES | REPORT_ALTERNATE_KEYS | REPORT_ASSOCIATED_TEXT

        let shiftedA = mapper.mapKittyKeyDown(
            event: keyEvent(
                modifierFlags: .shift,
                characters: "A",
                charactersIgnoringModifiers: "a"
            )
        )

        #expect(shiftedA == Data("\u{1B}[97:65;2;65u".utf8))
    }

    @Test
    func inputMapperLegacyControlProducesETXEvenWhenKittyEnabled() {
        let mapper = TerminalInputMapper()
        mapper.kittyKeyboardFlags = 7

        let ctrlC = keyEvent(
            keyCode: 8,
            modifierFlags: .control,
            characters: "\u{03}",
            charactersIgnoringModifiers: "c"
        )

        let legacy = mapper.mapLegacyControl(event: ctrlC)
        let kitty = mapper.mapKittyKeyDown(event: ctrlC)

        #expect(legacy == Data([0x03]))
        #expect(kitty == Data("\u{1B}[99;5u".utf8))
    }

    @Test
    func inputMapperMapsCommandArrowKeysToShellLineBoundaries() {
        let mapper = TerminalInputMapper()

        let commandLeft = mapper.map(event: keyEvent(keyCode: 123, modifierFlags: .command))
        let commandRight = mapper.map(event: keyEvent(keyCode: 124, modifierFlags: .command))

        #expect(commandLeft == Data([0x01]))
        #expect(commandRight == Data([0x05]))
    }

    @Test
    func terminalViewKeyDownSendsArrowInputToPTY() {
        let view = TerminalView(rows: 4, columns: 20)
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        view.keyDown(with: arrowKeyEvent(keyCode: 123))
        view.keyDown(with: arrowKeyEvent(keyCode: 124))

        #expect(capture.values == [Data("\u{1B}[D".utf8), Data("\u{1B}[C".utf8)])
    }

    @Test
    func terminalViewKeyDownSendsCommandArrowLineBoundariesToPTY() {
        let view = TerminalView(rows: 4, columns: 20)
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        view.keyDown(with: arrowKeyEvent(keyCode: 123, modifierFlags: .command))
        view.keyDown(with: arrowKeyEvent(keyCode: 124, modifierFlags: .command))

        #expect(capture.values == [Data([0x01]), Data([0x05])])
    }

    @Test
    func terminalViewPerformKeyEquivalentSendsCommandArrowLineBoundariesToPTY() {
        let view = TerminalView(rows: 4, columns: 20)
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        let handledLeft = view.performKeyEquivalent(with: arrowKeyEvent(keyCode: 123, modifierFlags: .command))
        let handledRight = view.performKeyEquivalent(with: arrowKeyEvent(keyCode: 124, modifierFlags: .command))

        #expect(handledLeft)
        #expect(handledRight)
        #expect(capture.values == [Data([0x01]), Data([0x05])])
    }

    @Test
    func terminalViewDoCommandSendsLineBoundarySelectorsToPTY() {
        let view = TerminalView(rows: 4, columns: 20)
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        view.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
        view.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))

        #expect(capture.values == [Data([0x01]), Data([0x05])])
    }

    @Test
    func terminalInputResumesAfterReEnablingKeyboardInput() {
        let view = TerminalView(rows: 4, columns: 20)
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        view.allowsKeyboardInput = false
        view.keyDown(with: arrowKeyEvent(keyCode: 123))
        #expect(capture.values.isEmpty)

        view.allowsKeyboardInput = true
        view.keyDown(with: arrowKeyEvent(keyCode: 123))

        #expect(capture.values == [Data("\u{1B}[D".utf8)])
    }

    @Test
    func terminalViewBuildsSGRMousePayload() {
        let view = TerminalView(rows: 10, columns: 10)
        let payload = view.mouseReportPayload(
            buttonCode: 0,
            row: 1,
            column: 2,
            isRelease: false,
            useSGR: true
        )

        #expect(payload == Data("\u{1B}[<0;3;2M".utf8))
    }

    @Test
    func terminalViewBuildsLegacyMousePayload() {
        let view = TerminalView(rows: 10, columns: 10)
        let payload = view.mouseReportPayload(
            buttonCode: 0,
            row: 1,
            column: 2,
            isRelease: false,
            useSGR: false
        )

        #expect(payload == Data([0x1B, 0x5B, 0x4D, 32, 35, 34]))
    }

    @Test
    func terminalViewAllowsSafeExternalURLSchemes() {
        let view = TerminalView(rows: 4, columns: 20)
        let safe = view.safeExternalURL(from: "https://example.com/path")
        #expect(safe?.absoluteString == "https://example.com/path")
    }

    @Test
    func terminalViewRejectsUnsafeExternalURLSchemes() {
        let view = TerminalView(rows: 4, columns: 20)
        #expect(view.safeExternalURL(from: "javascript:alert(1)") == nil)
        #expect(view.safeExternalURL(from: "file:///tmp/demo") == nil)
    }

    @Test
    func terminalViewBuildsRelativeLeftMovementForShellClick() {
        let view = makeShellPromptViewForTesting(command: "hello")
        let cursor = view.cursorBufferPositionForTesting()

        let payload = view.shellCursorRepositionInputForTesting(
            targetBufferRow: cursor.row,
            targetColumn: 2
        )

        #expect(payload == Data(String(repeating: "\u{1B}[D", count: max(0, cursor.column - 2)).utf8))
    }

    @Test
    func terminalViewBuildsRelativeRightMovementForShellClick() {
        let view = makeShellPromptViewForTesting(command: "hello", trailingEscape: "\u{1B}[3D")
        let cursor = view.cursorBufferPositionForTesting()

        let payload = view.shellCursorRepositionInputForTesting(
            targetBufferRow: cursor.row,
            targetColumn: cursor.column + 2
        )

        #expect(payload == Data(String(repeating: "\u{1B}[C", count: 2).utf8))
    }

    @Test
    func terminalViewDoesNotBuildShellClickMovementWhenMouseReportingEnabled() {
        let view = makeShellPromptViewForTesting(command: "hello")
        view.feed(data: Data("\u{1B}[?1000h".utf8))
        view.flushPendingOutputForTesting()
        let cursor = view.cursorBufferPositionForTesting()

        let payload = view.shellCursorRepositionInputForTesting(
            targetBufferRow: cursor.row,
            targetColumn: 2
        )

        #expect(payload == nil)
    }

    @Test
    func terminalViewBackspaceStillWorksAfterShellCursorClick() {
        let view = makeShellPromptViewForTesting(command: "hello")
        view.setFrameSize(NSSize(width: 400, height: 120))
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        let cursor = view.cursorBufferPositionForTesting()
        let point = view.pointForBufferCellForTesting(row: cursor.row, column: 2)

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: point))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: point))
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: backspaceEvent())

        let values = capture.values
        #expect(values.count >= 3)
        #expect(values[values.count - 2] == Data("a".utf8))
        #expect(values.last == Data([0x7F]))
    }

    @Test
    func terminalViewFirstRectUsesInsertionCaretGeometry() throws {
        let view = makeShellPromptViewForTesting(command: "hello")
        let window = hostViewInWindow(view, size: NSSize(width: 400, height: 120))
        defer { tearDownHostedWindow(window, view: view) }

        let cursor = view.cursorBufferPositionForTesting()
        let caretRect = localCaretRect(in: view)
        let cellWidth = view.pointForBufferCellForTesting(row: cursor.row, column: cursor.column).x
            - view.pointForBufferCellForTesting(row: cursor.row, column: max(0, cursor.column - 1)).x
        let currentCenterY = view.pointForBufferCellForTesting(row: cursor.row, column: cursor.column).y
        let nextRowCenterY = view.pointForBufferCellForTesting(row: cursor.row + 1, column: cursor.column).y
        let lineHeight = currentCenterY - nextRowCenterY
        let rowTopY = currentCenterY + (lineHeight * 0.5)
        let caretTopInset = rowTopY - caretRect.maxY

        #expect(caretRect.width < abs(cellWidth))
        #expect(caretRect.height < abs(lineHeight))
        #expect(caretTopInset <= 1.5)
    }

    @Test
    func terminalViewFocusedCaretBlinks() throws {
        let view = makeShellPromptViewForTesting(command: "hello")
        let window = hostViewInWindow(view, size: NSSize(width: 400, height: 120))
        defer { tearDownHostedWindow(window, view: view) }

        _ = window.makeFirstResponder(view)
        #expect(view.isCaretBlinkVisibleForTesting())

        view.advanceCaretBlinkForTesting()
        #expect(!view.isCaretBlinkVisibleForTesting())

        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.isCaretBlinkVisibleForTesting())
    }

    @Test
    func terminalViewKeepsCaretVisibleWhileCursorMovementContinues() {
        let view = makeShellPromptViewForTesting(command: "hello")
        #expect(view.isCaretBlinkVisibleForTesting())

        view.registerCaretMovementForTesting()
        view.registerCaretMovementForTesting()
        view.processCaretBlinkTickRelativeToSuppressionDeadlineForTesting(.milliseconds(-150))

        #expect(view.isCaretBlinkVisibleForTesting())
    }

    @Test
    func terminalViewResumesBlinkingAfterCursorMovementStops() {
        let view = makeShellPromptViewForTesting(command: "hello")
        #expect(view.isCaretBlinkVisibleForTesting())

        view.registerCaretMovementForTesting()
        view.registerCaretMovementForTesting()
        view.processCaretBlinkTickRelativeToSuppressionDeadlineForTesting(.milliseconds(1))

        #expect(!view.isCaretBlinkVisibleForTesting())
    }

    @Test
    func terminalViewFeedPublishesShellSnapshotWithoutVisibleLag() async {
        let view = TerminalView(rows: 4, columns: 20)
        view.setFrameSize(NSSize(width: 320, height: 120))
        view.flushPendingOutputForTesting()

        let clock = ContinuousClock()
        let start = clock.now
        view.feed(data: Data("$ x".utf8))

        let updated = await waitUntil(timeout: 0.1) {
            view.shellInputSnapshot()?.logicalLineText.contains("$ x") == true
        }
        let elapsed = milliseconds(start.duration(to: clock.now))

        #expect(updated)
        #expect(elapsed < 14, "Terminal view consumed shell output in \(elapsed)ms, which adds visible input lag.")
    }

    @Test
    func terminalViewShellClickUsesNearestCaretStop() {
        let view = makeShellPromptViewForTesting(command: "hello")
        view.setFrameSize(NSSize(width: 400, height: 120))
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        let cursor = view.cursorBufferPositionForTesting()
        let columnTwoCenter = view.pointForBufferCellForTesting(row: cursor.row, column: 2)
        let columnThreeCenter = view.pointForBufferCellForTesting(row: cursor.row, column: 3)
        let point = CGPoint(
            x: columnTwoCenter.x + (columnThreeCenter.x - columnTwoCenter.x) * 0.35,
            y: columnTwoCenter.y
        )

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: point))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: point))

        let expected = Data(String(repeating: "\u{1B}[D", count: max(0, cursor.column - 3)).utf8)
        #expect(capture.values == [expected])
    }

    @Test
    func terminalViewPublishesInteractionStateChanges() {
        let view = TerminalView(rows: 4, columns: 40)
        var snapshots: [TerminalInteractionState] = []
        view.onInteractionStateChange = { snapshots.append($0) }

        view.feed(data: Data("\u{1B}[?1049h".utf8))
        view.flushPendingOutputForTesting()

        #expect(snapshots.last?.isAlternateBufferActive == true)
        #expect(snapshots.last?.isInteractiveTerminalMode == true)

        view.feed(data: Data("\u{1B}[?1000h".utf8))
        view.flushPendingOutputForTesting()

        #expect(snapshots.last?.isMouseReportingEnabled == true)

        view.feed(data: Data("\u{1B}[?1h".utf8))
        view.flushPendingOutputForTesting()

        #expect(snapshots.last?.isApplicationCursorKeysEnabled == true)

        view.feed(data: Data("\u{1B}[?1049l\u{1B}[?1000l\u{1B}[?1l".utf8))
        view.flushPendingOutputForTesting()

        #expect(snapshots.last?.isAlternateBufferActive == false)
        #expect(snapshots.last?.isMouseReportingEnabled == false)
        #expect(snapshots.last?.isApplicationCursorKeysEnabled == false)
        #expect(snapshots.last?.isInteractiveTerminalMode == false)
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        keyCode: UInt16 = 0,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String = "",
        charactersIgnoringModifiers: String = "",
        isARepeat: Bool = false
    ) -> NSEvent {
        let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
        guard let event else {
            fatalError("Failed to create test key event")
        }
        return event
    }

    private func arrowKeyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        let scalar: UnicodeScalar
        switch keyCode {
        case 123:
            scalar = UnicodeScalar(NSLeftArrowFunctionKey)!
        case 124:
            scalar = UnicodeScalar(NSRightArrowFunctionKey)!
        case 125:
            scalar = UnicodeScalar(NSDownArrowFunctionKey)!
        case 126:
            scalar = UnicodeScalar(NSUpArrowFunctionKey)!
        default:
            fatalError("Unsupported arrow key code \(keyCode)")
        }

        let text = String(scalar)
        return keyEvent(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            characters: text,
            charactersIgnoringModifiers: text
        )
    }

    private func backspaceEvent() -> NSEvent {
        keyEvent(
            keyCode: 51,
            characters: String(UnicodeScalar(NSBackspaceCharacter)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSBackspaceCharacter)!)
        )
    }

    private func mouseEvent(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Failed to create mouse event")
        }
        return event
    }

    private func makeShellPromptViewForTesting(
        command: String,
        trailingEscape: String = ""
    ) -> TerminalView {
        let view = TerminalView(rows: 4, columns: 20)
        view.flushPendingOutputForTesting()
        view.feed(data: Data("\u{1B}[2J\u{1B}[H$ \(command)\(trailingEscape)".utf8))
        view.flushPendingOutputForTesting()
        return view
    }

    private func hostViewInWindow(_ view: TerminalView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        window.makeFirstResponder(view)
        window.displayIfNeeded()
        return window
    }

    private func tearDownHostedWindow(_ window: NSWindow, view: TerminalView) {
        if window.firstResponder as AnyObject? === view {
            window.makeFirstResponder(nil)
        }
        view.removeFromSuperview()
        window.orderOut(nil)
        window.contentView = nil
    }

    private func localCaretRect(in view: TerminalView) -> CGRect {
        let screenRect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        guard let window = view.window else {
            fatalError("Expected hosted window")
        }
        let windowRect = window.convertFromScreen(screenRect)
        return view.convert(windowRect, from: nil)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

}
