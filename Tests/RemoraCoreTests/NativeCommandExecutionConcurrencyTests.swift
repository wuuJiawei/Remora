import Foundation
import Testing
@testable import RemoraCore

@Suite("Native command execution concurrency")
struct NativeCommandExecutionConcurrencyTests {
    @Test("Command pump serializes native channel state reads")
    func commandPumpSerializesNativeChannelStateReads() throws {
        let sourceURL = packageRootURL()
            .appendingPathComponent("Sources/RemoraCore/RemoteCommand/LibSSH2CommandExecutor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let pump = try #require(source.range(of: "private func pump() async"))
        let read = try #require(source.range(of: "private func read(", range: pump.upperBound..<source.endIndex))
        let pumpSource = source[pump.lowerBound..<read.lowerBound]

        #expect(pumpSource.contains("try await runtime.perform"))
        #expect(!pumpSource.contains("if handle.isEOF"))
        #expect(!pumpSource.contains("continuation.yield(.exitStatus(handle.exitStatus))"))
    }

    private func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
