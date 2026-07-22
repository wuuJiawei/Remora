import Foundation
import RemoraSSHNative

public struct KeyboardInteractivePrompt: Equatable, Sendable {
    public let text: String
    public let echo: Bool

    public init(text: String, echo: Bool) {
        self.text = text
        self.echo = echo
    }
}

public struct KeyboardInteractiveChallenge: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let instruction: String
    public let prompts: [KeyboardInteractivePrompt]
    public let deadline: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instruction: String,
        prompts: [KeyboardInteractivePrompt],
        deadline: Date
    ) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
        self.deadline = deadline
    }
}

public final class AuthenticationCoordinator: @unchecked Sendable {
    let bridge: KeyboardInteractiveBridge

    public init(challengeTimeout: Duration = .seconds(300)) {
        bridge = KeyboardInteractiveBridge(challengeTimeout: challengeTimeout)
    }

    public func challenges() -> AsyncStream<KeyboardInteractiveChallenge> {
        bridge.challenges
    }

    @discardableResult
    public func respond(to challengeID: UUID, responses: [String]) -> Bool {
        bridge.respond(to: challengeID, responses: responses)
    }

    public func cancel() {
        bridge.cancel()
    }
}

final class KeyboardInteractiveBridge: @unchecked Sendable {
    let challenges: AsyncStream<KeyboardInteractiveChallenge>

    private let continuation: AsyncStream<KeyboardInteractiveChallenge>.Continuation
    private let condition = NSCondition()
    private let challengeTimeout: TimeInterval
    private var pendingChallenge: KeyboardInteractiveChallenge?
    private var pendingResponses: [String]?
    private var isCancelled = false

    init(challengeTimeout: Duration) {
        let stream = AsyncStream<KeyboardInteractiveChallenge>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        challenges = stream.stream
        continuation = stream.continuation
        self.challengeTimeout = challengeTimeout.timeInterval
    }

    deinit {
        cancel()
    }

    func requestResponses(
        name: String,
        instruction: String,
        prompts: [KeyboardInteractivePrompt]
    ) -> [String]? {
        guard !prompts.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(challengeTimeout)
        let challenge = KeyboardInteractiveChallenge(
            name: name,
            instruction: instruction,
            prompts: prompts,
            deadline: deadline
        )

        condition.lock()
        guard !isCancelled, pendingChallenge == nil else {
            condition.unlock()
            return nil
        }
        pendingChallenge = challenge
        pendingResponses = nil
        condition.unlock()

        continuation.yield(challenge)

        condition.lock()
        while pendingResponses == nil && !isCancelled {
            guard condition.wait(until: deadline) else { break }
        }
        let responses = pendingResponses
        pendingChallenge = nil
        pendingResponses = nil
        condition.unlock()

        guard responses?.count == prompts.count else { return nil }
        return responses
    }

    @discardableResult
    func respond(to challengeID: UUID, responses: [String]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !isCancelled,
              pendingChallenge?.id == challengeID,
              pendingChallenge?.prompts.count == responses.count
        else {
            return false
        }
        pendingResponses = responses
        condition.broadcast()
        return true
    }

    func cancel() {
        condition.lock()
        let shouldFinish = !isCancelled
        isCancelled = true
        condition.broadcast()
        condition.unlock()
        if shouldFinish {
            continuation.finish()
        }
    }
}

let nativeKeyboardChallengeHandler: remora_ssh_keyboard_challenge_handler = {
    context,
    nameBytes,
    nameLength,
    instructionBytes,
    instructionLength,
    promptPointer,
    promptCount,
    responsePointer in
    guard let context, let promptPointer, let responsePointer else { return false }
    let bridge = Unmanaged<KeyboardInteractiveBridge>.fromOpaque(context).takeUnretainedValue()
    let name = decodeNativeString(bytes: nameBytes, length: nameLength)
    let instruction = decodeNativeString(bytes: instructionBytes, length: instructionLength)

    var prompts: [KeyboardInteractivePrompt] = []
    prompts.reserveCapacity(promptCount)
    for index in 0..<promptCount {
        let nativePrompt = promptPointer.advanced(by: index).pointee
        prompts.append(
            KeyboardInteractivePrompt(
                text: decodeNativeString(bytes: nativePrompt.bytes, length: nativePrompt.length),
                echo: nativePrompt.echo
            )
        )
    }

    guard let responses = bridge.requestResponses(
        name: name,
        instruction: instruction,
        prompts: prompts
    ) else {
        return false
    }

    for (index, responseText) in responses.enumerated() {
        var responseBytes = Array(responseText.utf8)
        defer {
            _ = responseBytes.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        guard responseBytes.count <= REMORA_SSH_MAX_KEYBOARD_RESPONSE_BYTES else {
            return false
        }
        var nativeResponse = responsePointer.advanced(by: index).pointee
        withUnsafeMutableBytes(of: &nativeResponse.bytes) { destination in
            responseBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        nativeResponse.length = responseBytes.count
        responsePointer.advanced(by: index).pointee = nativeResponse
    }
    return true
}

private func decodeNativeString(bytes: UnsafePointer<UInt8>?, length: Int) -> String {
    guard let bytes, length > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        let seconds = Double(components.seconds)
        let fractionalSeconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0.001, seconds + fractionalSeconds)
    }
}
