import Foundation

// MARK: - ZMODEM Protocol Constants

/// ZMODEM frame types
public enum ZmodemFrameType: UInt8, Sendable {
    case ZRQINIT  = 0   // Request receive init
    case ZRINIT   = 1   // Receive init
    case ZSINIT   = 2   // Send init sequence
    case ZACK     = 3   // ACK
    case ZFILE    = 4   // File name from sender
    case ZSKIP    = 5   // Skip this file
    case ZNAK     = 6   // Last packet was garbled
    case ZABORT   = 7   // Abort batch transfers
    case ZFIN     = 8   // Finish session
    case ZRPOS    = 9   // Resume data trans at this position
    case ZDATA    = 10  // Data packet(s) follow
    case ZEOF     = 11  // End of file
    case ZFERR    = 12  // Fatal read or write error
    case ZCRC     = 13  // Request for file CRC and target position
    case ZCHALLENGE = 14 // Receiver's challenge
    case ZCOMPL   = 15  // Request is complete
    case ZCAN     = 16  // Pseudo frame: other end cancelled with CAN*5
    case ZFREECNT = 17  // Request for free bytes on filesystem
    case ZCOMMAND = 18  // Command from sending program
    case ZSTDERR  = 19  // Output to standard error
}

/// ZMODEM data sub-packet types
public enum ZmodemSubPacketType: UInt8, Sendable {
    case ZCRCE = 0x68  // 'h' - CRC next, frame ends, header follows
    case ZCRCG = 0x69  // 'i' - CRC next, frame continues nonstop
    case ZCRCQ = 0x6A  // 'j' - CRC next, frame continues, ZACK expected
    case ZCRCW = 0x6B  // 'k' - CRC next, frame ends, ZACK expected
}

/// ZMODEM encoding types
public enum ZmodemHeaderEncoding: UInt8, Sendable {
    case ZBIN   = 0x41  // 'A' - Binary header with 16-bit CRC
    case ZHEX   = 0x42  // 'B' - Hex header with 16-bit CRC
    case ZBIN32 = 0x43  // 'C' - Binary header with 32-bit CRC
}

/// ZMODEM special bytes
public enum ZmodemByte {
    public static let ZPAD: UInt8  = 0x2A  // '*' - Padding character
    public static let ZDLE: UInt8  = 0x18  // CAN - ZMODEM escape character
    public static let ZDLEE: UInt8 = 0x58  // 'X' - Escaped ZDLE
    public static let XON: UInt8   = 0x11
    public static let XOFF: UInt8  = 0x13
    public static let CR: UInt8    = 0x0D
    public static let LF: UInt8    = 0x0A
}

/// ZRINIT capability flags (ZF0)
public struct ZmodemRInitFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let canFDX  = ZmodemRInitFlags(rawValue: 0x01) // Rx can send and receive true FDX
    public static let canOVIO = ZmodemRInitFlags(rawValue: 0x02) // Rx can receive data during disk I/O
    public static let canBRK  = ZmodemRInitFlags(rawValue: 0x04) // Rx can send a break signal
    public static let canCRY  = ZmodemRInitFlags(rawValue: 0x08) // Receiver can decrypt
    public static let canLZW  = ZmodemRInitFlags(rawValue: 0x10) // Receiver can uncompress
    public static let canFC32 = ZmodemRInitFlags(rawValue: 0x20) // Rx can use 32 bit Frame Check
    public static let escCtl  = ZmodemRInitFlags(rawValue: 0x40) // Receiver expects ctl chars to be escaped
}

/// ZMODEM trigger detection signature
/// sz sends: "rz\r**\x18B00..." (ZRQINIT)
/// rz sends: "rz\r**\x18B01..." (ZRINIT, waiting for file)
public enum ZmodemTrigger: Sendable {
    case download  // Remote sz → client receives file
    case upload    // Remote rz → client sends file
}

/// ZMODEM CRC-16 (CCITT) lookup table
public let zmodemCRC16Table: [UInt16] = {
    var table = [UInt16](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt16(i) << 8
        for _ in 0..<8 {
            if crc & 0x8000 != 0 {
                crc = (crc << 1) ^ 0x1021
            } else {
                crc <<= 1
            }
        }
        table[i] = crc
    }
    return table
}()

/// ZMODEM CRC-32 lookup table
public let zmodemCRC32Table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt32(i)
        for _ in 0..<8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB88320
            } else {
                crc >>= 1
            }
        }
        table[i] = crc
    }
    return table
}()

public func zmodemCRC16(_ data: some Sequence<UInt8>, initial: UInt16 = 0) -> UInt16 {
    var crc = initial
    for byte in data {
        let index = Int(((crc >> 8) ^ UInt16(byte)) & 0xFF)
        crc = (crc << 8) ^ zmodemCRC16Table[index]
    }
    return crc
}

public func zmodemCRC32(_ data: some Sequence<UInt8>, initial: UInt32 = 0xFFFFFFFF) -> UInt32 {
    var crc = initial
    for byte in data {
        let index = Int((crc ^ UInt32(byte)) & 0xFF)
        crc = (crc >> 8) ^ zmodemCRC32Table[index]
    }
    return crc ^ 0xFFFFFFFF
}
