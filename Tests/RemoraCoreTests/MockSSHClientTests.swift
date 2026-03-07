import Foundation
import Testing
@testable import RemoraCore

struct MockSSHClientTests {
    @Test
    func mockShellSessionSupportsArrowEditing() async throws {
        let capture = OutputCapture()
        let session = MockShellSession(
            host: Host(
                name: "demo",
                address: "127.0.0.1",
                username: "tester",
                auth: HostAuth(method: .agent)
            ),
            pty: .init(columns: 120, rows: 30)
        )
        session.onOutput = { capture.append($0) }

        try await session.start()
        try await session.write(Data("hep".utf8))
        try await session.write(Data("\u{1B}[D".utf8))
        try await session.write(Data("l\r".utf8))

        let output = capture.combinedString
        #expect(output.contains("Available commands: help, date, whoami, ls, clear"))
    }

    @Test
    func mockShellSessionSupportsCommandStyleLineBoundariesAndBackspace() async throws {
        let capture = OutputCapture()
        let session = MockShellSession(
            host: Host(
                name: "demo",
                address: "127.0.0.1",
                username: "tester",
                auth: HostAuth(method: .agent)
            ),
            pty: .init(columns: 120, rows: 30)
        )
        session.onOutput = { capture.append($0) }

        try await session.start()
        try await session.write(Data("elp".utf8))
        try await session.write(Data([0x01]))
        try await session.write(Data("h".utf8))
        try await session.write(Data([0x05]))
        try await session.write(Data("\u{1B}[D".utf8))
        try await session.write(Data("a".utf8))
        try await session.write(Data([0x7F]))
        try await session.write(Data("\r".utf8))

        let output = capture.combinedString
        #expect(output.contains("Available commands: help, date, whoami, ls, clear, tui, exit-tui"))
    }

    @Test
    func mockShellSessionCanToggleAlternateBufferForTUIAutomation() async throws {
        let capture = OutputCapture()
        let session = MockShellSession(
            host: Host(
                name: "demo",
                address: "127.0.0.1",
                username: "tester",
                auth: HostAuth(method: .agent)
            ),
            pty: .init(columns: 120, rows: 30)
        )
        session.onOutput = { capture.append($0) }

        try await session.start()
        try await session.write(Data("tui\r".utf8))
        try await session.write(Data("exit-tui\r".utf8))

        let output = capture.combinedString
        #expect(output.contains("\u{001B}[?1049h"))
        #expect(output.contains("\u{001B}[?1049l"))
    }

    @Test
    func mockShellSessionCompletesKnownPathsOnTab() async throws {
        let capture = OutputCapture()
        let session = MockShellSession(
            host: Host(
                name: "demo",
                address: "127.0.0.1",
                username: "tester",
                auth: HostAuth(method: .agent)
            ),
            pty: .init(columns: 120, rows: 30)
        )
        session.onOutput = { capture.append($0) }

        try await session.start()
        try await session.write(Data("cd /t\t".utf8))

        let output = capture.combinedString
        #expect(output.contains("cd /tmp"))
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        chunks.append(data)
        lock.unlock()
    }

    var combinedString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: chunks.joined(), as: UTF8.self)
    }
}
