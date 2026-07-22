import Foundation
import Testing
@testable import RemoraCore

@Suite("Remote session hub")
struct RemoteSessionHubTests {
    @Test("Concurrent acquires share one session and release independently")
    func concurrentAcquiresShareOneSession() async throws {
        let key = makeSessionKey()
        let recorder = LifecycleRecorder()
        let hub = RemoteSessionHub()

        async let first = hub.acquire(key: key) {
            await recorder.recordFactoryCall()
            try await Task.sleep(for: .milliseconds(20))
            return RemoteSession(
                key: key,
                transport: RecordingSessionTransport(recorder: recorder)
            )
        }
        async let second = hub.acquire(key: key) {
            await recorder.recordFactoryCall()
            return RemoteSession(
                key: key,
                transport: RecordingSessionTransport(recorder: recorder)
            )
        }

        let (firstLease, secondLease) = try await (first, second)
        #expect(await recorder.factoryCalls == 1)
        #expect(await hub.activeSessionCount() == 1)
        #expect(await hub.activeLeaseCount(for: key) == 2)

        await firstLease.release()
        #expect(await recorder.transportCloseCount == 0)
        #expect(await hub.activeLeaseCount(for: key) == 1)

        await secondLease.release()
        #expect(await recorder.transportCloseCount == 1)
        #expect(await hub.activeSessionCount() == 0)
    }

    @Test("Last lease closes channels before transport")
    func lastLeaseClosesChannelsBeforeTransport() async throws {
        let key = makeSessionKey()
        let recorder = LifecycleRecorder()
        let hub = RemoteSessionHub()
        let lease = try await hub.acquire(key: key) {
            RemoteSession(
                key: key,
                transport: RecordingSessionTransport(recorder: recorder)
            )
        }
        let session = try await lease.session()
        _ = try await session.openShell(pty: PTYSize(columns: 80, rows: 24))

        await lease.release()

        #expect(await recorder.events == ["channel.close", "transport.close"])
    }

    @Test("Released lease cannot expose its session")
    func releasedLeaseRejectsUse() async throws {
        let key = makeSessionKey()
        let hub = RemoteSessionHub()
        let lease = try await hub.acquire(key: key) {
            RemoteSession(key: key, transport: RecordingSessionTransport(recorder: LifecycleRecorder()))
        }

        await lease.release()

        await #expect(throws: RemoteOperationError.self) {
            _ = try await lease.session()
        }
    }

    private func makeSessionKey() -> RemoteSessionKey {
        let hostID = UUID()
        return RemoteSessionKey(
            route: .direct(
                DirectConnectionRoute(
                    endpoint: RemoteEndpoint(hostname: "example.test"),
                    username: "tester"
                )
            ),
            target: RemoteTargetIdentity(
                savedHostID: hostID,
                routeProviderID: "direct",
                assetID: hostID.uuidString,
                assetDisplayName: "Fixture",
                accountUsername: "tester"
            ),
            authenticationIdentity: RemoteAuthenticationIdentity(
                username: "tester",
                method: .agent
            ),
            hostKeyPolicyID: "default"
        )
    }
}

private actor LifecycleRecorder {
    private(set) var factoryCalls = 0
    private(set) var transportCloseCount = 0
    private(set) var events: [String] = []

    func recordFactoryCall() {
        factoryCalls += 1
    }

    func recordChannelClose() {
        events.append("channel.close")
    }

    func recordTransportClose() {
        transportCloseCount += 1
        events.append("transport.close")
    }
}

private struct RecordingSessionTransport: RemoteSessionTransportProtocol {
    let recorder: LifecycleRecorder

    func openShell(pty: PTYSize) async throws -> any RemoteShellChannelProtocol {
        RecordingRemoteShellChannel(recorder: recorder)
    }

    func close() async {
        await recorder.recordTransportClose()
    }
}

private actor RecordingRemoteShellChannel: RemoteShellChannelProtocol {
    nonisolated let id = UUID()
    private let recorder: LifecycleRecorder

    init(recorder: LifecycleRecorder) {
        self.recorder = recorder
    }

    func start() async throws {}
    func write(_ data: Data) async throws {}
    func resize(_ size: PTYSize) async throws {}

    func events() async -> AsyncThrowingStream<RemoteShellEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    func close() async {
        await recorder.recordChannelClose()
    }
}
