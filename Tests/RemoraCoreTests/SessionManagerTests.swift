import Foundation
import Testing
@testable import RemoraCore

struct SessionManagerTests {
    @Test
    func startWriteAndStopSession() async throws {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let host = Host(
            name: "demo",
            address: "127.0.0.1",
            username: "tester",
            auth: HostAuth(method: .agent)
        )

        let descriptor = try await manager.startSession(for: host, pty: .init(columns: 100, rows: 30))
        let sessions = await manager.activeSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == descriptor.id)

        try await manager.write(Data("whoami\r".utf8), to: descriptor.id)

        await manager.stopSession(id: descriptor.id)
        let empty = await manager.activeSessions()
        #expect(empty.isEmpty)
    }

    @Test
    func outputStreamEmitsInitialBanner() async throws {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let host = Host(
            name: "demo",
            address: "127.0.0.1",
            username: "tester",
            auth: HostAuth(method: .agent)
        )

        let descriptor = try await manager.startSession(for: host, pty: .init(columns: 100, rows: 30))
        let stream = await manager.sessionOutputStream(sessionID: descriptor.id)

        let firstChunk = await firstChunkWithinOneSecond(from: stream)
        #expect(firstChunk != nil)
        #expect(String(decoding: firstChunk ?? Data(), as: UTF8.self).contains("Connected to"))

        await manager.stopSession(id: descriptor.id)
    }

    @Test
    func stateStreamEmitsRunningAndStopped() async throws {
        let manager = SessionManager(sshClientFactory: { MockSSHClient() })
        let host = Host(
            name: "demo",
            address: "127.0.0.1",
            username: "tester",
            auth: HostAuth(method: .agent)
        )

        let descriptor = try await manager.startSession(for: host, pty: .init(columns: 100, rows: 30))
        let states = await manager.sessionStateStream(sessionID: descriptor.id)
        var iterator = states.makeAsyncIterator()

        let running = await iterator.next()
        #expect(running == .running)

        await manager.stopSession(id: descriptor.id)
        let stopped = await iterator.next()
        #expect(stopped == .stopped)
    }

    private func firstChunkWithinOneSecond(
        from stream: AsyncStream<Data>
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

}
