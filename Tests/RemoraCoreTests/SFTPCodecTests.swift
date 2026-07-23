import Foundation
import Testing
@testable import RemoraCore

@Suite("SFTP wire codec")
struct SFTPCodecTests {
    @Test("Decoder accepts fragmented headers and payloads")
    func decoderAcceptsFragmentedFrames() throws {
        let frame = try SFTPCodec.encode(SFTPPacket(type: .data, payload: Data([1, 2, 3, 4])))
        var codec = SFTPCodec()

        #expect(try codec.append(Data(frame.prefix(3))).isEmpty)
        #expect(try codec.append(Data(frame.dropFirst(3).prefix(2))).isEmpty)
        #expect(try codec.append(Data(frame.dropFirst(5))) == [
            SFTPPacket(type: .data, payload: Data([1, 2, 3, 4])),
        ])
    }

    @Test("Decoder emits multiple complete frames")
    func decoderEmitsMultipleFrames() throws {
        let first = try SFTPCodec.encode(SFTPPacket(type: .status, payload: Data([1])))
        let second = try SFTPCodec.encode(SFTPPacket(type: .handle, payload: Data([2, 3])))
        var input = first
        input.append(second)
        var codec = SFTPCodec()

        #expect(try codec.append(input) == [
            SFTPPacket(type: .status, payload: Data([1])),
            SFTPPacket(type: .handle, payload: Data([2, 3])),
        ])
    }

    @Test("Declared packet length is rejected before payload arrives")
    func declaredPacketLengthIsBounded() {
        var codec = SFTPCodec(maximumPacketLength: 32)
        let oversizedHeader = Data([0, 0, 0, 33])

        #expect(throws: SFTPWireError.packetTooLarge(33)) {
            _ = try codec.append(oversizedHeader)
        }
    }

    @Test("Zero length packet is rejected")
    func zeroLengthPacketIsRejected() {
        var codec = SFTPCodec()

        #expect(throws: SFTPWireError.packetTooSmall) {
            _ = try codec.append(Data([0, 0, 0, 0]))
        }
    }

    @Test("Truncated attributes are rejected")
    func truncatedAttributesAreRejected() {
        var payload = SFTPDataWriter()
        payload.appendUInt32(7)
        payload.appendUInt32(SFTPFileAttributes.sizeFlag)
        payload.appendUInt32(1)
        let packet = SFTPPacket(type: .attrs, payload: payload.data)

        #expect(throws: SFTPWireError.truncatedPacket) {
            _ = try SFTPCodec().attributes(from: packet)
        }
    }

    @Test("Extended attribute count is bounded")
    func extendedAttributeCountIsBounded() {
        var payload = SFTPDataWriter()
        payload.appendUInt32(9)
        payload.appendUInt32(SFTPFileAttributes.extendedFlag)
        payload.appendUInt32(3)
        let packet = SFTPPacket(type: .attrs, payload: payload.data)
        let codec = SFTPCodec(maximumExtendedAttributeCount: 2)

        #expect(throws: SFTPWireError.attributeCountTooLarge(3)) {
            _ = try codec.attributes(from: packet)
        }
    }

    @Test("NAME entry count is bounded before allocation")
    func nameEntryCountIsBounded() {
        var payload = SFTPDataWriter()
        payload.appendUInt32(11)
        payload.appendUInt32(5)
        let packet = SFTPPacket(type: .name, payload: payload.data)
        let codec = SFTPCodec(maximumNameCount: 4)

        #expect(throws: SFTPWireError.nameCountTooLarge(5)) {
            _ = try codec.names(from: packet)
        }
    }

    @Test("Invalid UTF-8 filenames are rejected")
    func invalidUTF8FilenameIsRejected() {
        var payload = SFTPDataWriter()
        payload.appendUInt32(12)
        payload.appendUInt32(1)
        payload.appendDataString(Data([0xFF]))
        payload.appendString("")
        payload.appendUInt32(0)
        let packet = SFTPPacket(type: .name, payload: payload.data)

        #expect(throws: SFTPWireError.invalidUTF8) {
            _ = try SFTPCodec().names(from: packet)
        }
    }

    @Test("End of stream rejects an incomplete frame")
    func endOfStreamRejectsIncompleteFrame() throws {
        var codec = SFTPCodec()
        #expect(try codec.append(Data([0, 0, 0, 5, SFTPMessageType.data.rawValue, 1])).isEmpty)

        #expect(throws: SFTPWireError.truncatedPacket) {
            try codec.finish()
        }
    }

    @Test("STATUS rejects trailing bytes")
    func statusRejectsTrailingBytes() {
        var payload = SFTPDataWriter()
        payload.appendUInt32(1)
        payload.appendUInt32(SFTPStatusCode.ok.rawValue)
        payload.appendString("")
        payload.appendString("")
        payload.appendUInt8(0)

        #expect(throws: SFTPWireError.truncatedPacket) {
            _ = try SFTPCodec().status(from: SFTPPacket(type: .status, payload: payload.data))
        }
    }
}
