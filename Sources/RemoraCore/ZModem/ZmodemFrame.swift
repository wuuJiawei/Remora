import Foundation

// MARK: - ZMODEM Frame Construction & Parsing

/// A parsed ZMODEM header
public struct ZmodemHeader: Sendable, Equatable {
    public let type: ZmodemFrameType
    public let flags: (UInt8, UInt8, UInt8, UInt8) // ZF3, ZF2, ZF1, ZF0

    public init(type: ZmodemFrameType, p0: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0, p3: UInt8 = 0) {
        self.type = type
        self.flags = (p3, p2, p1, p0)
    }

    /// Interpret flags as a 32-bit file offset / position
    public var position: UInt32 {
        UInt32(flags.3) | (UInt32(flags.2) << 8) | (UInt32(flags.1) << 16) | (UInt32(flags.0) << 24)
    }

    /// Create a header with a 32-bit position value
    public static func withPosition(type: ZmodemFrameType, _ pos: UInt32) -> ZmodemHeader {
        ZmodemHeader(
            type: type,
            p0: UInt8(pos & 0xFF),
            p1: UInt8((pos >> 8) & 0xFF),
            p2: UInt8((pos >> 16) & 0xFF),
            p3: UInt8((pos >> 24) & 0xFF)
        )
    }

    public static func == (lhs: ZmodemHeader, rhs: ZmodemHeader) -> Bool {
        lhs.type == rhs.type
            && lhs.flags.0 == rhs.flags.0
            && lhs.flags.1 == rhs.flags.1
            && lhs.flags.2 == rhs.flags.2
            && lhs.flags.3 == rhs.flags.3
    }
}

// MARK: - Hex Header Encoding

/// Build a ZMODEM hex header: ZPAD ZPAD ZDLE ZHEX type[2] f0[2] f1[2] f2[2] f3[2] crc[4] CR LF XON
public func zmodemEncodeHexHeader(_ header: ZmodemHeader) -> Data {
    var bytes: [UInt8] = []
    bytes.append(ZmodemByte.ZPAD)
    bytes.append(ZmodemByte.ZPAD)
    bytes.append(ZmodemByte.ZDLE)
    bytes.append(ZmodemHeaderEncoding.ZHEX.rawValue)

    // Wire order: type, ZF0, ZF1, ZF2, ZF3 — which is p0, p1, p2, p3
    let payload: [UInt8] = [header.type.rawValue, header.flags.3, header.flags.2, header.flags.1, header.flags.0]
    let crc = zmodemCRC16(payload)

    for b in payload {
        bytes.append(contentsOf: hexEncode(b))
    }
    bytes.append(contentsOf: hexEncode(UInt8((crc >> 8) & 0xFF)))
    bytes.append(contentsOf: hexEncode(UInt8(crc & 0xFF)))
    bytes.append(ZmodemByte.CR)
    bytes.append(ZmodemByte.LF)

    // Append XON unless it's ZFIN or ZACK
    if header.type != .ZFIN && header.type != .ZACK {
        bytes.append(ZmodemByte.XON)
    }

    return Data(bytes)
}

/// Build a ZMODEM binary header with CRC-32
public func zmodemEncodeBin32Header(_ header: ZmodemHeader) -> Data {
    var bytes: [UInt8] = []
    bytes.append(ZmodemByte.ZPAD)
    bytes.append(ZmodemByte.ZDLE)
    bytes.append(ZmodemHeaderEncoding.ZBIN32.rawValue)

    // Wire order: type, ZF0, ZF1, ZF2, ZF3 — which is p0, p1, p2, p3
    let payload: [UInt8] = [header.type.rawValue, header.flags.3, header.flags.2, header.flags.1, header.flags.0]
    let crc = zmodemCRC32(payload)

    for b in payload {
        zmodemAppendEscaped(b, to: &bytes)
    }
    let crcBytes: [UInt8] = [
        UInt8(crc & 0xFF),
        UInt8((crc >> 8) & 0xFF),
        UInt8((crc >> 16) & 0xFF),
        UInt8((crc >> 24) & 0xFF),
    ]
    for b in crcBytes {
        zmodemAppendEscaped(b, to: &bytes)
    }

    return Data(bytes)
}

// MARK: - Hex Header Parsing

/// Attempt to parse a hex header from a buffer starting after "ZPAD ZPAD ZDLE ZHEX".
/// Returns the parsed header and the number of bytes consumed (including trailing CR LF [XON]),
/// or nil if the buffer is incomplete / invalid.
public func zmodemParseHexHeader(_ buffer: ArraySlice<UInt8>) -> (header: ZmodemHeader, consumed: Int)? {
    // Need at least 14 hex chars (type[2] + 4*flags[8] + crc[4]) = 14 hex chars
    guard buffer.count >= 14 else { return nil }
    let startIndex = buffer.startIndex

    guard let typeByte = hexDecode(buffer[startIndex], buffer[startIndex + 1]),
          let f0 = hexDecode(buffer[startIndex + 2], buffer[startIndex + 3]),
          let f1 = hexDecode(buffer[startIndex + 4], buffer[startIndex + 5]),
          let f2 = hexDecode(buffer[startIndex + 6], buffer[startIndex + 7]),
          let f3 = hexDecode(buffer[startIndex + 8], buffer[startIndex + 9]),
          let crcHi = hexDecode(buffer[startIndex + 10], buffer[startIndex + 11]),
          let crcLo = hexDecode(buffer[startIndex + 12], buffer[startIndex + 13])
    else { return nil }

    guard let frameType = ZmodemFrameType(rawValue: typeByte) else { return nil }

    let payload: [UInt8] = [typeByte, f0, f1, f2, f3]
    let expectedCRC = zmodemCRC16(payload)
    let actualCRC = (UInt16(crcHi) << 8) | UInt16(crcLo)
    guard expectedCRC == actualCRC else { return nil }

    // Skip trailing CR LF [XON]
    var consumed = 14
    let remaining = buffer.dropFirst(14)
    var skip = remaining.startIndex
    if skip < remaining.endIndex, remaining[skip] == ZmodemByte.CR { skip += 1; consumed += 1 }
    if skip < remaining.endIndex, remaining[skip] == ZmodemByte.LF { skip += 1; consumed += 1 }
    if skip < remaining.endIndex, remaining[skip] == ZmodemByte.XON { skip += 1; consumed += 1 }

    let header = ZmodemHeader(type: frameType, p0: f0, p1: f1, p2: f2, p3: f3)
    return (header, consumed)
}

// MARK: - Binary Header Parsing (CRC-16)

public func zmodemParseBinHeader(_ buffer: ArraySlice<UInt8>) -> (header: ZmodemHeader, consumed: Int)? {
    var idx = buffer.startIndex
    var decoded: [UInt8] = []
    // Need 5 payload bytes + 2 CRC bytes = 7 decoded bytes
    while decoded.count < 7, idx < buffer.endIndex {
        let b = buffer[idx]
        idx += 1
        if b == ZmodemByte.ZDLE {
            guard idx < buffer.endIndex else { return nil }
            let next = buffer[idx]
            idx += 1
            decoded.append(next ^ 0x40)
        } else {
            decoded.append(b)
        }
    }
    guard decoded.count >= 7 else { return nil }

    guard let frameType = ZmodemFrameType(rawValue: decoded[0]) else { return nil }
    let payload = Array(decoded[0..<5])
    let expectedCRC = zmodemCRC16(payload)
    let actualCRC = (UInt16(decoded[5]) << 8) | UInt16(decoded[6])
    guard expectedCRC == actualCRC else { return nil }

    let header = ZmodemHeader(type: frameType, p0: decoded[1], p1: decoded[2], p2: decoded[3], p3: decoded[4])
    return (header, idx - buffer.startIndex)
}

// MARK: - Binary Header Parsing (CRC-32)

public func zmodemParseBin32Header(_ buffer: ArraySlice<UInt8>) -> (header: ZmodemHeader, consumed: Int)? {
    var idx = buffer.startIndex
    var decoded: [UInt8] = []
    // Need 5 payload bytes + 4 CRC bytes = 9 decoded bytes
    while decoded.count < 9, idx < buffer.endIndex {
        let b = buffer[idx]
        idx += 1
        if b == ZmodemByte.ZDLE {
            guard idx < buffer.endIndex else { return nil }
            let next = buffer[idx]
            idx += 1
            decoded.append(next ^ 0x40)
        } else {
            decoded.append(b)
        }
    }
    guard decoded.count >= 9 else { return nil }

    guard let frameType = ZmodemFrameType(rawValue: decoded[0]) else { return nil }
    let payload = Array(decoded[0..<5])
    let expectedCRC = zmodemCRC32(payload)
    let actualCRC = UInt32(decoded[5])
        | (UInt32(decoded[6]) << 8)
        | (UInt32(decoded[7]) << 16)
        | (UInt32(decoded[8]) << 24)
    guard expectedCRC == actualCRC else { return nil }

    let header = ZmodemHeader(type: frameType, p0: decoded[1], p1: decoded[2], p2: decoded[3], p3: decoded[4])
    return (header, idx - buffer.startIndex)
}

// MARK: - Sub-packet Data Parsing (CRC-32)

/// Parse a ZMODEM data sub-packet with CRC-32.
/// Returns (payload, subPacketType, bytesConsumed) or nil if incomplete/invalid.
public func zmodemParseSubPacket32(_ buffer: ArraySlice<UInt8>) -> (data: Data, end: ZmodemSubPacketType, consumed: Int)? {
    var idx = buffer.startIndex
    var payload: [UInt8] = []

    // Scan for ZDLE + sub-packet-type
    while idx < buffer.endIndex {
        let b = buffer[idx]
        idx += 1

        if b == ZmodemByte.ZDLE {
            guard idx < buffer.endIndex else { return nil }
            let next = buffer[idx]
            idx += 1

            if let subType = ZmodemSubPacketType(rawValue: next) {
                // Found end marker. Next 4 bytes (escaped) are CRC-32
                var crcBytes: [UInt8] = []
                while crcBytes.count < 4, idx < buffer.endIndex {
                    let cb = buffer[idx]
                    idx += 1
                    if cb == ZmodemByte.ZDLE {
                        guard idx < buffer.endIndex else { return nil }
                        let cn = buffer[idx]
                        idx += 1
                        crcBytes.append(cn ^ 0x40)
                    } else {
                        crcBytes.append(cb)
                    }
                }
                guard crcBytes.count == 4 else { return nil }

                // CRC covers payload + sub-packet type byte
                var crcInput = payload
                crcInput.append(subType.rawValue)
                let expectedCRC = zmodemCRC32(crcInput)
                let actualCRC = UInt32(crcBytes[0])
                    | (UInt32(crcBytes[1]) << 8)
                    | (UInt32(crcBytes[2]) << 16)
                    | (UInt32(crcBytes[3]) << 24)
                guard expectedCRC == actualCRC else { return nil }

                return (Data(payload), subType, idx - buffer.startIndex)
            } else {
                // Escaped data byte
                payload.append(next ^ 0x40)
            }
        } else {
            payload.append(b)
        }
    }

    return nil // Incomplete
}

// MARK: - Sub-packet Data Parsing (CRC-16)

public func zmodemParseSubPacket16(_ buffer: ArraySlice<UInt8>) -> (data: Data, end: ZmodemSubPacketType, consumed: Int)? {
    var idx = buffer.startIndex
    var payload: [UInt8] = []

    while idx < buffer.endIndex {
        let b = buffer[idx]
        idx += 1

        if b == ZmodemByte.ZDLE {
            guard idx < buffer.endIndex else { return nil }
            let next = buffer[idx]
            idx += 1

            if let subType = ZmodemSubPacketType(rawValue: next) {
                var crcBytes: [UInt8] = []
                while crcBytes.count < 2, idx < buffer.endIndex {
                    let cb = buffer[idx]
                    idx += 1
                    if cb == ZmodemByte.ZDLE {
                        guard idx < buffer.endIndex else { return nil }
                        let cn = buffer[idx]
                        idx += 1
                        crcBytes.append(cn ^ 0x40)
                    } else {
                        crcBytes.append(cb)
                    }
                }
                guard crcBytes.count == 2 else { return nil }

                var crcInput = payload
                crcInput.append(subType.rawValue)
                let expectedCRC = zmodemCRC16(crcInput)
                let actualCRC = (UInt16(crcBytes[0]) << 8) | UInt16(crcBytes[1])
                guard expectedCRC == actualCRC else { return nil }

                return (Data(payload), subType, idx - buffer.startIndex)
            } else {
                payload.append(next ^ 0x40)
            }
        } else {
            payload.append(b)
        }
    }

    return nil
}

// MARK: - Sub-packet Data Encoding (CRC-32)

/// Encode a ZMODEM data sub-packet with CRC-32.
public func zmodemEncodeSubPacket32(_ data: Data, type: ZmodemSubPacketType) -> Data {
    var bytes: [UInt8] = []
    let raw = Array(data)

    for b in raw {
        zmodemAppendEscaped(b, to: &bytes)
    }

    // ZDLE + sub-packet type
    bytes.append(ZmodemByte.ZDLE)
    bytes.append(type.rawValue)

    // CRC-32 covers payload + sub-packet type byte
    var crcInput = raw
    crcInput.append(type.rawValue)
    let crc = zmodemCRC32(crcInput)
    let crcBytes: [UInt8] = [
        UInt8(crc & 0xFF),
        UInt8((crc >> 8) & 0xFF),
        UInt8((crc >> 16) & 0xFF),
        UInt8((crc >> 24) & 0xFF),
    ]
    for b in crcBytes {
        zmodemAppendEscaped(b, to: &bytes)
    }

    return Data(bytes)
}

// MARK: - Helpers

private func hexEncode(_ byte: UInt8) -> [UInt8] {
    let hi = byte >> 4
    let lo = byte & 0x0F
    return [hexChar(hi), hexChar(lo)]
}

private func hexChar(_ nibble: UInt8) -> UInt8 {
    nibble < 10 ? (0x30 + nibble) : (0x61 + nibble - 10)
}

private func hexDecode(_ hi: UInt8, _ lo: UInt8) -> UInt8? {
    guard let h = hexVal(hi), let l = hexVal(lo) else { return nil }
    return (h << 4) | l
}

private func hexVal(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

/// Append a byte with ZDLE escaping if needed.
/// Escapes all control characters (0x00-0x1F, 0x7F, 0x80-0x9F) for maximum
/// compatibility with bastion hosts and multi-hop SSH connections.
func zmodemAppendEscaped(_ byte: UInt8, to buffer: inout [UInt8]) {
    switch byte {
    case ZmodemByte.ZDLE:
        buffer.append(ZmodemByte.ZDLE)
        buffer.append(ZmodemByte.ZDLEE)
    case 0x10, 0x11, 0x13, 0x0D:
        // DLE, XON, XOFF, CR — always escape
        buffer.append(ZmodemByte.ZDLE)
        buffer.append(byte ^ 0x40)
    case 0x00...0x1F, 0x7F, 0x80...0x9F:
        // All control characters — escape for -e compatibility
        buffer.append(ZmodemByte.ZDLE)
        buffer.append(byte ^ 0x40)
    default:
        buffer.append(byte)
    }
}
