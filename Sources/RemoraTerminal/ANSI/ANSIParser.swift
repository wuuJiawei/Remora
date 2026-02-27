import Foundation

public final class ANSIParser {
    private enum State {
        case ground
        case escape
        case csi([UInt8])
    }

    private var state: State = .ground

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
            } else {
                state = .ground
            }
        case .csi(var bytes):
            if (0x40 ... 0x7E).contains(byte) {
                executeCSI(finalByte: byte, paramsBytes: bytes, screen: screen)
                state = .ground
            } else {
                bytes.append(byte)
                state = .csi(bytes)
            }
        }
    }

    private func handleGround(byte: UInt8, screen: ScreenBuffer) {
        switch byte {
        case 0x1B:
            state = .escape
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
            if params.first == 2 {
                screen.clearScreen()
            }
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
        default:
            break
        }
    }

    private func parseParams(_ raw: String) -> [Int] {
        if raw.isEmpty { return [] }
        return raw.split(separator: ";").map { Int($0) ?? 0 }
    }
}
