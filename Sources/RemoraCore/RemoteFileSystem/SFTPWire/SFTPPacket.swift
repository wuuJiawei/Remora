import Foundation

enum SFTPMessageType: UInt8, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0
    case endOfFile = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case operationUnsupported = 8
}

struct SFTPPacket: Equatable, Sendable {
    let type: UInt8
    let payload: Data

    init(type: UInt8, payload: Data) {
        self.type = type
        self.payload = payload
    }

    init(type: SFTPMessageType, payload: Data) {
        self.init(type: type.rawValue, payload: payload)
    }
}

struct SFTPFileAttributes: Equatable, Sendable {
    static let sizeFlag: UInt32 = 0x0000_0001
    static let uidGIDFlag: UInt32 = 0x0000_0002
    static let permissionsFlag: UInt32 = 0x0000_0004
    static let accessModificationTimeFlag: UInt32 = 0x0000_0008
    static let extendedFlag: UInt32 = 0x8000_0000

    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var accessTime: UInt32?
    var modificationTime: UInt32?
    var extensions: [SFTPExtendedAttribute] = []
}

struct SFTPExtendedAttribute: Equatable, Sendable {
    var type: Data
    var data: Data
}

struct SFTPNameEntry: Equatable, Sendable {
    var filename: String
    var longname: String
    var attributes: SFTPFileAttributes
}

struct SFTPStatus: Equatable, Sendable {
    var requestID: UInt32
    var code: UInt32
    var message: String
    var language: String
}

enum SFTPWireError: Error, Equatable, Sendable {
    case packetTooSmall
    case packetTooLarge(Int)
    case truncatedPacket
    case invalidUTF8
    case stringTooLarge(Int)
    case attributeCountTooLarge(Int)
    case nameCountTooLarge(Int)
    case invalidVersion(UInt32)
    case unexpectedPacketType(UInt8)
    case missingRequestID
    case tooManyOutstandingRequests(Int)
    case duplicateRequestID(UInt32)
    case unknownRequestID(UInt32)
    case requestIDExhausted
    case channelClosed
}
