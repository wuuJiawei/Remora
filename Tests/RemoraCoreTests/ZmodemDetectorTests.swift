import Foundation
import Testing
@testable import RemoraCore

struct ZmodemDetectorTests {
    @Test
    func detectsDownloadTriggerAndPreservesLeadingPassthrough() {
        var detector = ZmodemDetector()
        let bytes = Data(Array("hello".utf8) + [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30, 0x41])

        let result = detector.feed(bytes)

        #expect(result.trigger == .download)
        #expect(String(decoding: result.passthrough, as: UTF8.self) == "hello")
        #expect(Array(result.trailingData.prefix(6)) == [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30])
    }

    @Test
    func detectsUploadTriggerAcrossChunkBoundary() {
        var detector = ZmodemDetector()

        let first = detector.feed(Data([0x58, 0x2A, 0x2A, 0x18]))
        #expect(first.trigger == nil)
        #expect(Array(first.passthrough) == [0x58, 0x2A, 0x2A, 0x18])

        let second = detector.feed(Data([0x42, 0x30, 0x31, 0x5A]))
        #expect(second.trigger == .upload)
        #expect(second.passthrough.isEmpty)
        #expect(Array(second.trailingData.prefix(7)) == [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x31, 0x5A])
    }

    @Test
    func resetClearsPartialBoundaryState() {
        var detector = ZmodemDetector()

        _ = detector.feed(Data([0x2A, 0x2A, 0x18]))
        detector.reset()

        let result = detector.feed(Data([0x42, 0x30, 0x30]))
        #expect(result.trigger == nil)
        #expect(Array(result.passthrough) == [0x42, 0x30, 0x30])
    }
}
