import AppKit
import Foundation
import Testing
@testable import RemoraTerminal

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
}
