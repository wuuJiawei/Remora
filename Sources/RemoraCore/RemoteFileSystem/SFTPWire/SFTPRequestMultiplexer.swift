import Foundation

actor SFTPRequestMultiplexer {
    typealias SendFrame = @Sendable (Data) async throws -> Void

    private struct PendingRequest {
        let expectedTypes: Set<UInt8>
        let continuation: CheckedContinuation<SFTPPacket, Error>
    }

    private let maximumOutstandingRequests: Int
    private let codec: SFTPCodec
    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: PendingRequest] = [:]
    private var completedRequestIDs: Set<UInt32> = []
    private var completedRequestOrder: [UInt32] = []
    private var abandonedRequestIDs: Set<UInt32> = []
    private var abandonedRequestOrder: [UInt32] = []
    private var terminalError: Error?

    init(
        maximumOutstandingRequests: Int = 64,
        codec: SFTPCodec = SFTPCodec()
    ) {
        self.maximumOutstandingRequests = max(1, maximumOutstandingRequests)
        self.codec = codec
    }

    func request(
        type: SFTPMessageType,
        payload: Data = Data(),
        expecting expectedTypes: Set<SFTPMessageType>,
        send: @escaping SendFrame
    ) async throws -> SFTPPacket {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard pending.count < maximumOutstandingRequests else {
            throw SFTPWireError.tooManyOutstandingRequests(maximumOutstandingRequests)
        }
        let requestID = try allocateRequestID()
        let frame = try SFTPCodec.request(type: type, id: requestID, payload: payload)
        let rawExpectedTypes = Set(expectedTypes.map(\.rawValue)).union([SFTPMessageType.status.rawValue])

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[requestID] = PendingRequest(
                    expectedTypes: rawExpectedTypes,
                    continuation: continuation
                )
                Task {
                    guard self.pending[requestID] != nil else { return }
                    do {
                        try await send(frame)
                    } catch {
                        self.failAll(error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: requestID) }
        }
    }

    func receive(_ packet: SFTPPacket) throws {
        if let terminalError { throw terminalError }
        let requestID = try codec.requestID(in: packet)
        guard let request = pending.removeValue(forKey: requestID) else {
            if abandonedRequestIDs.remove(requestID) != nil {
                abandonedRequestOrder.removeAll { $0 == requestID }
                rememberCompletedRequestID(requestID)
                return
            }
            let error = completedRequestIDs.contains(requestID)
                ? SFTPWireError.duplicateRequestID(requestID)
                : SFTPWireError.unknownRequestID(requestID)
            failAll(error)
            throw error
        }
        guard request.expectedTypes.contains(packet.type) else {
            let error = SFTPWireError.unexpectedPacketType(packet.type)
            request.continuation.resume(throwing: error)
            failAll(error)
            throw error
        }
        rememberCompletedRequestID(requestID)
        request.continuation.resume(returning: packet)
    }

    func failAll(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let requests = pending.values
        pending.removeAll(keepingCapacity: false)
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }

    func outstandingRequestCount() -> Int {
        pending.count
    }

    private func cancelRequest(id: UInt32) {
        guard let request = pending.removeValue(forKey: id) else { return }
        rememberAbandonedRequestID(id)
        request.continuation.resume(throwing: CancellationError())
    }

    private func allocateRequestID() throws -> UInt32 {
        let start = nextRequestID
        repeat {
            let candidate = nextRequestID
            nextRequestID = candidate == UInt32.max ? 1 : candidate + 1
            if pending[candidate] == nil,
               !completedRequestIDs.contains(candidate),
               !abandonedRequestIDs.contains(candidate)
            {
                return candidate
            }
        } while nextRequestID != start
        throw SFTPWireError.requestIDExhausted
    }

    private func rememberCompletedRequestID(_ requestID: UInt32) {
        completedRequestIDs.insert(requestID)
        completedRequestOrder.append(requestID)
        if completedRequestOrder.count > 256 {
            completedRequestIDs.remove(completedRequestOrder.removeFirst())
        }
    }

    private func rememberAbandonedRequestID(_ requestID: UInt32) {
        abandonedRequestIDs.insert(requestID)
        abandonedRequestOrder.append(requestID)
        if abandonedRequestOrder.count > 256 {
            abandonedRequestIDs.remove(abandonedRequestOrder.removeFirst())
        }
    }
}
