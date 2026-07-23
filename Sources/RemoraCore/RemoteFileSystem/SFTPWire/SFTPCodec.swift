import Foundation

struct SFTPCodec: Sendable {
    static let protocolVersion: UInt32 = 3
    static let defaultMaximumPacketLength = 1 * 1_024 * 1_024
    static let defaultMaximumStringLength = 256 * 1_024
    static let defaultMaximumNameCount = 4_096
    static let defaultMaximumExtendedAttributeCount = 64

    let maximumPacketLength: Int
    let maximumStringLength: Int
    let maximumNameCount: Int
    let maximumExtendedAttributeCount: Int

    private var bufferedData = Data()
    private var readOffset = 0

    init(
        maximumPacketLength: Int = SFTPCodec.defaultMaximumPacketLength,
        maximumStringLength: Int = SFTPCodec.defaultMaximumStringLength,
        maximumNameCount: Int = SFTPCodec.defaultMaximumNameCount,
        maximumExtendedAttributeCount: Int = SFTPCodec.defaultMaximumExtendedAttributeCount
    ) {
        self.maximumPacketLength = max(1, maximumPacketLength)
        self.maximumStringLength = max(1, min(maximumStringLength, maximumPacketLength))
        self.maximumNameCount = max(1, maximumNameCount)
        self.maximumExtendedAttributeCount = max(0, maximumExtendedAttributeCount)
    }

    mutating func append(_ data: Data) throws -> [SFTPPacket] {
        if readOffset == bufferedData.count {
            bufferedData.removeAll(keepingCapacity: true)
            readOffset = 0
        }
        bufferedData.append(data)

        var packets: [SFTPPacket] = []
        while bufferedData.count - readOffset >= 4 {
            let declaredLength = Int(Self.readUInt32(bufferedData, at: readOffset))
            guard declaredLength >= 1 else { throw SFTPWireError.packetTooSmall }
            guard declaredLength <= maximumPacketLength else {
                throw SFTPWireError.packetTooLarge(declaredLength)
            }
            let frameLength = 4 + declaredLength
            guard bufferedData.count - readOffset >= frameLength else { break }

            let typeOffset = readOffset + 4
            let payloadStart = typeOffset + 1
            let frameEnd = readOffset + frameLength
            packets.append(
                SFTPPacket(
                    type: bufferedData[typeOffset],
                    payload: Data(bufferedData[payloadStart ..< frameEnd])
                )
            )
            readOffset = frameEnd
        }

        if readOffset > 64 * 1_024 {
            bufferedData.removeSubrange(0 ..< readOffset)
            readOffset = 0
        }
        return packets
    }

    mutating func finish() throws {
        guard bufferedData.count == readOffset else {
            throw SFTPWireError.truncatedPacket
        }
        bufferedData.removeAll(keepingCapacity: false)
        readOffset = 0
    }

    static func encode(_ packet: SFTPPacket, maximumPacketLength: Int = defaultMaximumPacketLength) throws -> Data {
        let packetLength = 1 + packet.payload.count
        guard packetLength <= maximumPacketLength else {
            throw SFTPWireError.packetTooLarge(packetLength)
        }
        var writer = SFTPDataWriter()
        writer.appendUInt32(UInt32(packetLength))
        writer.appendUInt8(packet.type)
        writer.appendData(packet.payload)
        return writer.data
    }

    static func initialization(version: UInt32 = protocolVersion) throws -> Data {
        var writer = SFTPDataWriter()
        writer.appendUInt32(version)
        return try encode(SFTPPacket(type: .initialize, payload: writer.data))
    }

    static func request(type: SFTPMessageType, id: UInt32, payload: Data = Data()) throws -> Data {
        var writer = SFTPDataWriter()
        writer.appendUInt32(id)
        writer.appendData(payload)
        return try encode(SFTPPacket(type: type, payload: writer.data))
    }

    func parseVersion(_ packet: SFTPPacket) throws -> (version: UInt32, extensions: [String: Data]) {
        guard packet.type == SFTPMessageType.version.rawValue else {
            throw SFTPWireError.unexpectedPacketType(packet.type)
        }
        var reader = SFTPDataReader(
            data: packet.payload,
            maximumStringLength: maximumStringLength,
            maximumExtendedAttributeCount: maximumExtendedAttributeCount
        )
        let version = try reader.readUInt32()
        var extensions: [String: Data] = [:]
        var count = 0
        while !reader.isAtEnd {
            count += 1
            guard count <= maximumExtendedAttributeCount else {
                throw SFTPWireError.attributeCountTooLarge(count)
            }
            let name = try reader.readString()
            extensions[name] = try reader.readDataString()
        }
        return (version, extensions)
    }

    func requestID(in packet: SFTPPacket) throws -> UInt32 {
        guard packet.payload.count >= 4 else { throw SFTPWireError.missingRequestID }
        return Self.readUInt32(packet.payload, at: packet.payload.startIndex)
    }

    func status(from packet: SFTPPacket) throws -> SFTPStatus {
        guard packet.type == SFTPMessageType.status.rawValue else {
            throw SFTPWireError.unexpectedPacketType(packet.type)
        }
        var reader = makeReader(packet.payload)
        let status = SFTPStatus(
            requestID: try reader.readUInt32(),
            code: try reader.readUInt32(),
            message: try reader.readString(),
            language: try reader.readString()
        )
        try reader.requireEnd()
        return status
    }

    func handle(from packet: SFTPPacket) throws -> Data {
        guard packet.type == SFTPMessageType.handle.rawValue else {
            throw SFTPWireError.unexpectedPacketType(packet.type)
        }
        var reader = makeReader(packet.payload)
        _ = try reader.readUInt32()
        let handle = try reader.readDataString()
        try reader.requireEnd()
        return handle
    }

    func fileData(from packet: SFTPPacket) throws -> Data {
        guard packet.type == SFTPMessageType.data.rawValue else {
            throw SFTPWireError.unexpectedPacketType(packet.type)
        }
        var reader = makeReader(packet.payload)
        _ = try reader.readUInt32()
        let data = try reader.readDataString()
        try reader.requireEnd()
        return data
    }

    func attributes(from packet: SFTPPacket) throws -> SFTPFileAttributes {
        guard packet.type == SFTPMessageType.attrs.rawValue else {
            throw SFTPWireError.unexpectedPacketType(packet.type)
        }
        var reader = makeReader(packet.payload)
        _ = try reader.readUInt32()
        let attributes = try reader.readAttributes()
        try reader.requireEnd()
        return attributes
    }

    func names(from packet: SFTPPacket) throws -> [SFTPNameEntry] {
        guard packet.type == SFTPMessageType.name.rawValue else {
            throw SFTPWireError.unexpectedPacketType(packet.type)
        }
        var reader = makeReader(packet.payload)
        _ = try reader.readUInt32()
        let count = Int(try reader.readUInt32())
        guard count <= maximumNameCount else { throw SFTPWireError.nameCountTooLarge(count) }
        var names: [SFTPNameEntry] = []
        names.reserveCapacity(count)
        for _ in 0 ..< count {
            names.append(
                SFTPNameEntry(
                    filename: try reader.readString(),
                    longname: try reader.readString(),
                    attributes: try reader.readAttributes()
                )
            )
        }
        try reader.requireEnd()
        return names
    }

    private func makeReader(_ data: Data) -> SFTPDataReader {
        SFTPDataReader(
            data: data,
            maximumStringLength: maximumStringLength,
            maximumExtendedAttributeCount: maximumExtendedAttributeCount
        )
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start ..< start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

struct SFTPDataWriter: Sendable {
    private(set) var data = Data()

    mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(truncatingIfNeeded: value >> 32))
        appendUInt32(UInt32(truncatingIfNeeded: value))
    }

    mutating func appendData(_ value: Data) {
        data.append(value)
    }

    mutating func appendDataString(_ value: Data) {
        appendUInt32(UInt32(value.count))
        appendData(value)
    }

    mutating func appendString(_ value: String) {
        appendDataString(Data(value.utf8))
    }

    mutating func appendAttributes(_ attributes: SFTPFileAttributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTPFileAttributes.sizeFlag }
        if attributes.uid != nil, attributes.gid != nil { flags |= SFTPFileAttributes.uidGIDFlag }
        if attributes.permissions != nil { flags |= SFTPFileAttributes.permissionsFlag }
        if attributes.accessTime != nil, attributes.modificationTime != nil {
            flags |= SFTPFileAttributes.accessModificationTimeFlag
        }
        if !attributes.extensions.isEmpty { flags |= SFTPFileAttributes.extendedFlag }
        appendUInt32(flags)
        if let size = attributes.size { appendUInt64(size) }
        if let uid = attributes.uid, let gid = attributes.gid {
            appendUInt32(uid)
            appendUInt32(gid)
        }
        if let permissions = attributes.permissions { appendUInt32(permissions) }
        if let accessTime = attributes.accessTime, let modificationTime = attributes.modificationTime {
            appendUInt32(accessTime)
            appendUInt32(modificationTime)
        }
        if !attributes.extensions.isEmpty {
            appendUInt32(UInt32(attributes.extensions.count))
            for attribute in attributes.extensions {
                appendDataString(attribute.type)
                appendDataString(attribute.data)
            }
        }
    }
}

struct SFTPDataReader: Sendable {
    private let data: Data
    private let maximumStringLength: Int
    private let maximumExtendedAttributeCount: Int
    private var offset = 0

    init(data: Data, maximumStringLength: Int, maximumExtendedAttributeCount: Int) {
        self.data = data
        self.maximumStringLength = maximumStringLength
        self.maximumExtendedAttributeCount = maximumExtendedAttributeCount
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw SFTPWireError.truncatedPacket }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let high = UInt64(try readUInt32())
        let low = UInt64(try readUInt32())
        return (high << 32) | low
    }

    mutating func readDataString() throws -> Data {
        let length = Int(try readUInt32())
        guard length <= maximumStringLength else { throw SFTPWireError.stringTooLarge(length) }
        return try read(count: length)
    }

    mutating func readString() throws -> String {
        let value = try readDataString()
        guard let string = String(data: value, encoding: .utf8) else {
            throw SFTPWireError.invalidUTF8
        }
        return string
    }

    mutating func readAttributes() throws -> SFTPFileAttributes {
        let flags = try readUInt32()
        var attributes = SFTPFileAttributes()
        if flags & SFTPFileAttributes.sizeFlag != 0 {
            attributes.size = try readUInt64()
        }
        if flags & SFTPFileAttributes.uidGIDFlag != 0 {
            attributes.uid = try readUInt32()
            attributes.gid = try readUInt32()
        }
        if flags & SFTPFileAttributes.permissionsFlag != 0 {
            attributes.permissions = try readUInt32()
        }
        if flags & SFTPFileAttributes.accessModificationTimeFlag != 0 {
            attributes.accessTime = try readUInt32()
            attributes.modificationTime = try readUInt32()
        }
        if flags & SFTPFileAttributes.extendedFlag != 0 {
            let count = Int(try readUInt32())
            guard count <= maximumExtendedAttributeCount else {
                throw SFTPWireError.attributeCountTooLarge(count)
            }
            attributes.extensions.reserveCapacity(count)
            for _ in 0 ..< count {
                attributes.extensions.append(
                    SFTPExtendedAttribute(type: try readDataString(), data: try readDataString())
                )
            }
        }
        return attributes
    }

    mutating func requireEnd() throws {
        guard isAtEnd else { throw SFTPWireError.truncatedPacket }
    }

    private mutating func read(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw SFTPWireError.truncatedPacket
        }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start ..< start + count])
    }
}
