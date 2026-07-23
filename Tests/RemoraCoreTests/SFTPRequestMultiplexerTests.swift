import Foundation
import Testing
@testable import RemoraCore

@Suite("SFTP request multiplexer")
struct SFTPRequestMultiplexerTests {
    @Test("Responses are matched by request ID rather than arrival order")
    func responsesAreReorderedByRequestID() async throws {
        let multiplexer = SFTPRequestMultiplexer()
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        var iterator = pair.stream.makeAsyncIterator()

        let firstTask = Task {
            try await multiplexer.request(type: .stat, expecting: [.attrs]) {
                pair.continuation.yield($0)
            }
        }
        let firstID = try requestID(from: try #require(await iterator.next()))
        let secondTask = Task {
            try await multiplexer.request(type: .lstat, expecting: [.attrs]) {
                pair.continuation.yield($0)
            }
        }
        let secondID = try requestID(from: try #require(await iterator.next()))

        let secondResponse = response(type: .attrs, id: secondID)
        let firstResponse = response(type: .attrs, id: firstID)
        try await multiplexer.receive(secondResponse)
        try await multiplexer.receive(firstResponse)

        #expect(try await firstTask.value == firstResponse)
        #expect(try await secondTask.value == secondResponse)
    }

    @Test("Outstanding request count is capped")
    func outstandingRequestCountIsCapped() async throws {
        let multiplexer = SFTPRequestMultiplexer(maximumOutstandingRequests: 1)
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        var iterator = pair.stream.makeAsyncIterator()
        let pending = Task {
            try await multiplexer.request(type: .stat, expecting: [.attrs]) {
                pair.continuation.yield($0)
            }
        }
        _ = try #require(await iterator.next())

        await #expect(throws: SFTPWireError.tooManyOutstandingRequests(1)) {
            _ = try await multiplexer.request(type: .lstat, expecting: [.attrs]) { _ in }
        }

        pending.cancel()
        _ = try? await pending.value
    }

    @Test("Duplicate response IDs fail the multiplexer")
    func duplicateResponseIDIsRejected() async throws {
        let multiplexer = SFTPRequestMultiplexer()
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        var iterator = pair.stream.makeAsyncIterator()
        let task = Task {
            try await multiplexer.request(type: .stat, expecting: [.attrs]) {
                pair.continuation.yield($0)
            }
        }
        let requestID = try requestID(from: try #require(await iterator.next()))
        let packet = response(type: .attrs, id: requestID)
        try await multiplexer.receive(packet)
        _ = try await task.value

        await #expect(throws: SFTPWireError.duplicateRequestID(requestID)) {
            try await multiplexer.receive(packet)
        }
    }

    @Test("Unknown response IDs fail the multiplexer")
    func unknownResponseIDIsRejected() async {
        let multiplexer = SFTPRequestMultiplexer()

        await #expect(throws: SFTPWireError.unknownRequestID(404)) {
            try await multiplexer.receive(response(type: .attrs, id: 404))
        }
    }

    @Test("Already cancelled requests are never registered or sent")
    func alreadyCancelledRequestIsNotRegistered() async {
        let multiplexer = SFTPRequestMultiplexer()
        let sends = SendCounter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await multiplexer.request(type: .stat, expecting: [.attrs]) { _ in
                await sends.increment()
            }
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await sends.value == 0)
        #expect(await multiplexer.outstandingRequestCount() == 0)
    }

    @Test("Late response to a cancelled request is discarded once")
    func lateCancelledResponseDoesNotFailOtherRequests() async throws {
        let multiplexer = SFTPRequestMultiplexer()
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        var iterator = pair.stream.makeAsyncIterator()
        let cancelled = Task {
            try await multiplexer.request(type: .stat, expecting: [.attrs]) {
                pair.continuation.yield($0)
            }
        }
        let cancelledID = try requestID(from: try #require(await iterator.next()))
        cancelled.cancel()
        _ = try? await cancelled.value

        try await multiplexer.receive(response(type: .attrs, id: cancelledID))

        let active = Task {
            try await multiplexer.request(type: .lstat, expecting: [.attrs]) {
                pair.continuation.yield($0)
            }
        }
        let activeID = try requestID(from: try #require(await iterator.next()))
        let activeResponse = response(type: .attrs, id: activeID)
        try await multiplexer.receive(activeResponse)
        #expect(try await active.value == activeResponse)
    }

    private func requestID(from frame: Data) throws -> UInt32 {
        var codec = SFTPCodec()
        guard let packet = try codec.append(frame).first else {
            throw SFTPWireError.truncatedPacket
        }
        return try codec.requestID(in: packet)
    }

    private func response(type: SFTPMessageType, id: UInt32) -> SFTPPacket {
        var payload = SFTPDataWriter()
        payload.appendUInt32(id)
        return SFTPPacket(type: type, payload: payload.data)
    }
}

private actor SendCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
