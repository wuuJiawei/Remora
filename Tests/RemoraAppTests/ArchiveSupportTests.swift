import Foundation
import Testing
@testable import RemoraApp

struct ArchiveSupportTests {
    @Test
    func extractFormatRecognizesSupportedNames() {
        #expect(ArchiveFormat.extractFormat(for: "demo.zip") == .zip)
        #expect(ArchiveFormat.extractFormat(for: "demo.tar") == .tar)
        #expect(ArchiveFormat.extractFormat(for: "demo.tar.gz") == .tarGz)
        #expect(ArchiveFormat.extractFormat(for: "demo.tgz") == .tgz)
        #expect(ArchiveFormat.extractFormat(for: "demo.gz") == .gz)
    }

    @Test
    func defaultArchiveNameUsesFormatExtension() {
        #expect(ArchiveSupport.defaultArchiveName(for: "logs", format: .zip) == "logs.zip")
        #expect(ArchiveSupport.defaultArchiveName(for: "logs", format: .tarGz) == "logs.tar.gz")
    }

    @Test
    func zipArchiveRoundTripPreservesFiles() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-support-zip-\(UUID().uuidString)")
        let source = tempRoot.appendingPathComponent("source")
        let extract = tempRoot.appendingPathComponent("extract")
        let archive = tempRoot.appendingPathComponent("bundle.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: nested.appendingPathComponent("b.txt"))

        try ArchiveSupport.createArchive(from: source, destinationURL: archive, format: .zip)
        try ArchiveSupport.extractArchive(at: archive, to: extract)

        let a = try String(contentsOf: extract.appendingPathComponent("a.txt"))
        let b = try String(contentsOf: extract.appendingPathComponent("nested/b.txt"))
        #expect(a == "hello")
        #expect(b == "world")
    }

    @Test
    func tarGzArchiveRoundTripPreservesFiles() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-support-tgz-\(UUID().uuidString)")
        let source = tempRoot.appendingPathComponent("source")
        let extract = tempRoot.appendingPathComponent("extract")
        let archive = tempRoot.appendingPathComponent("bundle.tar.gz")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try Data("alpha".utf8).write(to: source.appendingPathComponent("alpha.txt"))

        try ArchiveSupport.createArchive(from: source, destinationURL: archive, format: .tarGz)
        try ArchiveSupport.extractArchive(at: archive, to: extract)

        let text = try String(contentsOf: extract.appendingPathComponent("alpha.txt"))
        #expect(text == "alpha")
    }

    @Test
    func gzExtractionProducesSingleFile() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-support-gz-\(UUID().uuidString)")
        let input = tempRoot.appendingPathComponent("input.txt")
        let archive = tempRoot.appendingPathComponent("input.txt.gz")
        let extract = tempRoot.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try Data("gzip-body".utf8).write(to: input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", input.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try data.write(to: archive)

        try ArchiveSupport.extractArchive(at: archive, to: extract)
        let text = try String(contentsOf: extract.appendingPathComponent("input.txt"))
        #expect(text == "gzip-body")
    }
}
