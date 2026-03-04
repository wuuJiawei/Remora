import Foundation

public final class ANSIParser {
    // Terminal modes
    public var mouseReportingEnabled: Bool = false
    public var sgrMouseModeEnabled: Bool = false
    public var bracketedPasteEnabled: Bool = false
    public var focusReportingEnabled: Bool = false

    // Callbacks for terminal queries
    public var onDSR: ((_ row: Int, _ col: Int) -> Void)?
    public var onDA: (() -> Void)?
    public var onCUU: (() -> Void)?  // Cursor up
    public var onCUD: (() -> Void)?  // Cursor down
    public var onCUF: (() -> Void)?  // Cursor forward
    public var onCUB: (() -> Void)?  // Cursor back
    public var onKittyKeyboardQuery: ((_ flags: Int) -> Void)?
    public private(set) var applicationCursorKeysEnabled: Bool = false
    public private(set) var kittyKeyboardFlags: Int = 0
    
    private enum State {
        case ground
        case escape
        case csi([UInt8])
        case ss3
        case osc
        case oscEscape
    }

    private var state: State = .ground
    private var pendingUTF8Bytes: [UInt8] = []
    private var expectedUTF8ByteCount: Int?
    private var kittyMainFlags: Int = 0
    private var kittyAltFlags: Int = 0
    private var kittyMainStack: [Int] = []
    private var kittyAltStack: [Int] = []
    private var kittyAlternateBufferActive: Bool = false

    public init() {}

    public func parse(_ data: Data, into screen: ScreenBuffer) {
        for byte in data {
            step(byte: byte, screen: screen)
        }
    }

    private func step(byte: UInt8, screen: ScreenBuffer) {
        switch state {
        case .ground:
            handleGround(byte: byte, screen: screen)
        case .escape:
            if byte == UInt8(ascii: "[") {
                state = .csi([])
            } else if byte == UInt8(ascii: "O") {
                state = .ss3
            } else if byte == UInt8(ascii: "]") {
                state = .osc
            } else if byte == UInt8(ascii: "7") {
                // DECSC - Save Cursor
                screen.saveCursor()
                state = .ground
            } else if byte == UInt8(ascii: "8") {
                // DECRC - Restore Cursor
                screen.restoreCursor()
                state = .ground
            } else if byte == UInt8(ascii: "D") {
                // IND - Index (move down, scroll up at bottom margin)
                screen.lineFeed()
                state = .ground
            } else if byte == UInt8(ascii: "E") {
                // NEL - Next line (line feed + carriage return)
                screen.lineFeed()
                screen.carriageReturn()
                state = .ground
            } else if byte == UInt8(ascii: "M") {
                // RI - Reverse index (move up, scroll down at top margin)
                screen.reverseIndex()
                state = .ground
            } else {
                state = .ground
            }
        case .csi(var bytes):
            if (0x40 ... 0x7E).contains(byte) {
                executeCSI(finalByte: byte, paramsBytes: bytes, screen: screen)
                state = .ground
            } else if (0x20 ... 0x3F).contains(byte) {
                bytes.append(byte)
                state = .csi(bytes)
            } else if byte == 0x1B {
                // Broken/incomplete CSI followed by a new ESC sequence.
                state = .escape
            } else {
                // Invalid CSI byte: abort sequence without leaking bytes as text.
                state = .ground
                handleGround(byte: byte, screen: screen)
            }
        case .ss3:
            // SS3 (ESC O <final>) often encodes cursor moves in application mode.
            switch byte {
            case UInt8(ascii: "A"):
                screen.moveCursor(deltaRow: -1)
            case UInt8(ascii: "B"):
                screen.moveCursor(deltaRow: 1)
            case UInt8(ascii: "C"):
                screen.moveCursor(deltaColumn: 1)
            case UInt8(ascii: "D"):
                screen.moveCursor(deltaColumn: -1)
            default:
                break
            }
            state = .ground
        case .osc:
            if byte == 0x07 {
                state = .ground
            } else if byte == 0x1B {
                state = .oscEscape
            }
        case .oscEscape:
            if byte == UInt8(ascii: "\\") {
                state = .ground
            } else if byte != 0x1B {
                state = .osc
            }
        }
    }

    private func handleGround(byte: UInt8, screen: ScreenBuffer) {
        if !pendingUTF8Bytes.isEmpty {
            if isUTF8ContinuationByte(byte) {
                consumeUTF8(byte: byte, screen: screen)
                return
            }
            resetPendingUTF8()
        }

        switch byte {
        case 0x1B:
            state = .escape
        case 0x9B:
            // C1 CSI control, equivalent to ESC [
            state = .csi([])
        case 0x0A:
            screen.lineFeed()
        case 0x0D:
            screen.carriageReturn()
        case 0x08:
            screen.backspace()
        case 0x09:
            screen.horizontalTab()
        case 0x20 ... 0x7E:
            if let scalar = UnicodeScalar(Int(byte)) {
                screen.put(character: Character(scalar))
            }
        case 0xC2 ... 0xF4:
            consumeUTF8(byte: byte, screen: screen)
        default:
            break
        }
    }

    private func executeCSI(finalByte: UInt8, paramsBytes: [UInt8], screen: ScreenBuffer) {
        let paramsString = String(decoding: paramsBytes, as: UTF8.self)
        let params = parseParams(paramsString)

        switch finalByte {
        case UInt8(ascii: "m"):
            screen.applySGR(parameters: params)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            let row = (params.first ?? 1) - 1
            let col = (params.dropFirst().first ?? 1) - 1
            screen.moveCursor(row: row, column: col)
        case UInt8(ascii: "J"):
            screen.clearScreen(mode: params.first ?? 0)
        case UInt8(ascii: "K"):
            screen.clearLine(mode: params.first ?? 0)
        case UInt8(ascii: "A"):
            screen.moveCursor(deltaRow: -(params.first ?? 1))
        case UInt8(ascii: "B"):
            screen.moveCursor(deltaRow: params.first ?? 1)
        case UInt8(ascii: "C"):
            screen.moveCursor(deltaColumn: params.first ?? 1)
        case UInt8(ascii: "D"):
            screen.moveCursor(deltaColumn: -(params.first ?? 1))
        case UInt8(ascii: "G"):
            let column = max(1, params.first ?? 1) - 1
            screen.moveCursor(column: column)
        case UInt8(ascii: "r"):
            if params.isEmpty {
                screen.setScrollingRegion(top: 0, bottom: screen.rows - 1)
            } else {
                let rawTop = params.first ?? 1
                let rawBottom = params.dropFirst().first ?? screen.rows
                let top = rawTop <= 0 ? 1 : rawTop
                let bottom = max(top, rawBottom <= 0 ? screen.rows : rawBottom)
                screen.setScrollingRegion(top: top - 1, bottom: bottom - 1)
            }
        case UInt8(ascii: "S"):
            screen.scrollUp(lines: params.first ?? 1)
        case UInt8(ascii: "h"):
            // Private mode set (DECSET)
            handlePrivateModeSet(paramsString: paramsString, screen: screen)
        case UInt8(ascii: "l"):
            // Private mode reset (DECRST)
            handlePrivateModeReset(paramsString: paramsString, screen: screen)
        case UInt8(ascii: "n"):
            // DSR - Device Status Report (CSI 6n)
            // Reports cursor position as ESC[row;colR
            if paramsString.isEmpty || paramsString == "5" {
                // DSR 5 = Status report (OK)
                // Not typically used, but we handle it
            } else if paramsString == "6" {
                // DSR 6 = Cursor position report
                // Callback will handle sending response
                onDSR?(screen.cursorRow + 1, screen.cursorColumn + 1)
            }
        case UInt8(ascii: "c"):
            // DA - Device Attributes (CSI c)
            // Response: ESC[?1;2c (VT100 with advanced video option)
            if paramsString.isEmpty || paramsString == "0" {
                onDA?()
            }
        case UInt8(ascii: "s"):
            // SCP - Save Cursor Position (alternative to ESC 7).
            // Guard against private/proprietary forms like CSI ?u / CSI >u.
            if paramsString.isEmpty || paramsString == "0" {
                screen.saveCursor()
                onCUU?()  // Notify (same as ESC 7)
            }
        case UInt8(ascii: "u"):
            // Kitty keyboard protocol and RCP overlap on final byte 'u'.
            if handleKittyKeyboardControl(paramsString) {
                break
            }
            // RCP - Restore Cursor Position (alternative to ESC 8).
            if paramsString.isEmpty || paramsString == "0" {
                screen.restoreCursor()
                onCUD?()  // Notify (same as ESC 8)
            }
        default:
            // Unknown CSI sequence - swallow (do nothing, don't output garbage)
            break
        }
    }
    
    // MARK: - Private Mode Handlers
    
    private func handlePrivateModeSet(paramsString: String, screen: ScreenBuffer) {
        // Handle ?XXXXh sequences
        if paramsString.hasPrefix("?") {
            let modes = paramsString.dropFirst().split(separator: ";").map(String.init)
            for modeStr in modes {
                switch modeStr {
                case "1":
                    // DECCKM - application cursor keys mode.
                    applicationCursorKeysEnabled = true
                case "25":
                    // Show cursor.
                    screen.setCursorVisible(true)
                case "1049":
                    // Alt screen + save cursor.
                    activateKittyAltFlags()
                    screen.saveCursor()
                    screen.enterAlternateBuffer()
                case "47", "1047":
                    // Alt screen (no cursor save).
                    activateKittyAltFlags()
                    screen.enterAlternateBuffer()
                case "1048":
                    // Save cursor (handled by ESC 7)
                    screen.saveCursor()
                case "1000", "1002", "1003":
                    // Mouse tracking modes
                    mouseReportingEnabled = true
                case "1006":
                    // SGR extended mouse coordinates.
                    sgrMouseModeEnabled = true
                case "1004":
                    // Focus in/out reporting (CSI I / CSI O)
                    focusReportingEnabled = true
                case "2004":
                    // Bracketed paste
                    bracketedPasteEnabled = true
                case "2026":
                    // Synchronized updates.
                    screen.beginSynchronizedUpdate()
                default:
                    break
                }
            }
        }
    }
    
    private func handlePrivateModeReset(paramsString: String, screen: ScreenBuffer) {
        // Handle ?XXXXl sequences
        if paramsString.hasPrefix("?") {
            let modes = paramsString.dropFirst().split(separator: ";").map(String.init)
            for modeStr in modes {
                switch modeStr {
                case "1":
                    // DECCKM - normal cursor keys mode.
                    applicationCursorKeysEnabled = false
                case "25":
                    // Hide cursor.
                    screen.setCursorVisible(false)
                case "1049":
                    // Leave alt screen + restore cursor.
                    screen.leaveAlternateBuffer()
                    deactivateKittyAltFlags()
                    screen.restoreCursor()
                case "47", "1047":
                    // Leave alt screen.
                    screen.leaveAlternateBuffer()
                    deactivateKittyAltFlags()
                case "1048":
                    // Restore cursor (handled by ESC 8)
                    screen.restoreCursor()
                case "1000", "1002", "1003":
                    // Disable mouse tracking
                    mouseReportingEnabled = false
                case "1006":
                    // Disable SGR mouse coordinates.
                    sgrMouseModeEnabled = false
                case "1004":
                    // Disable focus reporting.
                    focusReportingEnabled = false
                case "2004":
                    // Disable bracketed paste
                    bracketedPasteEnabled = false
                case "2026":
                    // End synchronized updates and force full redraw.
                    screen.endSynchronizedUpdate()
                default:
                    break
                }
            }
        }
    }

    private func parseParams(_ raw: String) -> [Int] {
        if raw.isEmpty { return [] }
        return raw.split(separator: ";").map { Int($0) ?? 0 }
    }

    // MARK: - Kitty Keyboard Protocol (CSI ... u)

    private func handleKittyKeyboardControl(_ paramsString: String) -> Bool {
        if let params = parsePrefixedParams(paramsString, prefix: "=") {
            let flags = params.first ?? 0
            let mode = params.dropFirst().first ?? 1
            switch mode {
            case 1:
                kittyKeyboardFlags = flags
            case 2:
                kittyKeyboardFlags |= flags
            case 3:
                kittyKeyboardFlags &= ~flags
            default:
                break
            }
            syncKittyFlagsForActiveBuffer()
            return true
        }

        if let params = parsePrefixedParams(paramsString, prefix: "?") {
            if params.isEmpty {
                onKittyKeyboardQuery?(kittyKeyboardFlags)
                return true
            }
            return false
        }

        if let params = parsePrefixedParams(paramsString, prefix: ">") {
            let flags = params.first ?? 0
            if kittyAlternateBufferActive {
                if kittyAltStack.count >= 16 {
                    kittyAltStack.removeFirst()
                }
                kittyAltStack.append(kittyAltFlags)
            } else {
                if kittyMainStack.count >= 16 {
                    kittyMainStack.removeFirst()
                }
                kittyMainStack.append(kittyMainFlags)
            }
            kittyKeyboardFlags = flags
            syncKittyFlagsForActiveBuffer()
            return true
        }

        if let params = parsePrefixedParams(paramsString, prefix: "<") {
            let count = max(1, params.first ?? 1)
            if kittyAlternateBufferActive {
                var popped = false
                for _ in 0..<count where !kittyAltStack.isEmpty {
                    kittyKeyboardFlags = kittyAltStack.removeLast()
                    popped = true
                }
                if !popped {
                    kittyKeyboardFlags = 0
                }
            } else {
                var popped = false
                for _ in 0..<count where !kittyMainStack.isEmpty {
                    kittyKeyboardFlags = kittyMainStack.removeLast()
                    popped = true
                }
                if !popped {
                    kittyKeyboardFlags = 0
                }
            }
            syncKittyFlagsForActiveBuffer()
            return true
        }

        return false
    }

    private func parsePrefixedParams(_ raw: String, prefix: Character) -> [Int]? {
        guard raw.first == prefix else { return nil }
        let payload = String(raw.dropFirst())
        guard !payload.isEmpty else { return [] }
        return payload.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    private func activateKittyAltFlags() {
        kittyMainFlags = kittyKeyboardFlags
        kittyKeyboardFlags = kittyAltFlags
        kittyAlternateBufferActive = true
    }

    private func deactivateKittyAltFlags() {
        kittyAltFlags = kittyKeyboardFlags
        kittyKeyboardFlags = kittyMainFlags
        kittyAlternateBufferActive = false
    }

    private func syncKittyFlagsForActiveBuffer() {
        if kittyAlternateBufferActive {
            kittyAltFlags = kittyKeyboardFlags
        } else {
            kittyMainFlags = kittyKeyboardFlags
        }
    }

    private func consumeUTF8(byte: UInt8, screen: ScreenBuffer) {
        if pendingUTF8Bytes.isEmpty {
            guard let expectedLength = expectedUTF8Length(forLeadingByte: byte) else {
                return
            }
            pendingUTF8Bytes.append(byte)
            expectedUTF8ByteCount = expectedLength
            return
        }

        guard isUTF8ContinuationByte(byte) else {
            resetPendingUTF8()
            return
        }

        pendingUTF8Bytes.append(byte)
        guard let expectedUTF8ByteCount, pendingUTF8Bytes.count >= expectedUTF8ByteCount else {
            return
        }

        if let decoded = String(data: Data(pendingUTF8Bytes), encoding: .utf8) {
            for character in decoded {
                screen.put(character: character)
            }
        }
        resetPendingUTF8()
    }

    private func resetPendingUTF8() {
        pendingUTF8Bytes.removeAll(keepingCapacity: true)
        expectedUTF8ByteCount = nil
    }

    private func expectedUTF8Length(forLeadingByte byte: UInt8) -> Int? {
        switch byte {
        case 0xC2 ... 0xDF:
            return 2
        case 0xE0 ... 0xEF:
            return 3
        case 0xF0 ... 0xF4:
            return 4
        default:
            return nil
        }
    }

    private func isUTF8ContinuationByte(_ byte: UInt8) -> Bool {
        (0x80 ... 0xBF).contains(byte)
    }
}
