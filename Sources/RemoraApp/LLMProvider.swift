import Foundation

enum LLMRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct LLMMessage: Equatable, Codable, Sendable {
    var role: LLMRole
    var content: String

    init(role: LLMRole, content: String) {
        self.role = role
        self.content = content
    }
}

struct LLMOptions: Equatable, Sendable {
    var model: String
    var temperature: Double
    var maxOutputTokens: Int?

    static let `default` = LLMOptions(
        model: "mock-default",
        temperature: 0.2,
        maxOutputTokens: nil
    )
}

struct LLMUsage: Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int {
        promptTokens + completionTokens
    }
}

enum LLMStopReason: String, Equatable, Sendable {
    case completed
    case length
    case toolCall
}

struct LLMCompletion: Equatable, Sendable {
    var message: LLMMessage
    var stopReason: LLMStopReason
    var usage: LLMUsage
}

struct LLMTool: Equatable, Sendable {
    var name: String
    var description: String
    var inputSchemaJSON: String
}

struct LLMToolCall: Equatable, Sendable {
    var toolName: String
    var argumentsJSON: String
}

struct LLMToolResult: Equatable, Sendable {
    var toolCalls: [LLMToolCall]
    var assistantMessage: LLMMessage?
}

enum LLMStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCall(LLMToolCall)
    case completed(LLMCompletion)
}

protocol LLMProvider: Sendable {
    var identifier: String { get }

    func chat(messages: [LLMMessage], options: LLMOptions) async throws -> LLMCompletion

    func toolCall(
        messages: [LLMMessage],
        tools: [LLMTool],
        options: LLMOptions
    ) async throws -> LLMToolResult

    func stream(
        messages: [LLMMessage],
        tools: [LLMTool]?,
        options: LLMOptions
    ) async throws -> AsyncThrowingStream<LLMStreamEvent, Error>
}

enum LLMProviderError: LocalizedError, Equatable, Sendable {
    case emptyMessages

    var errorDescription: String? {
        switch self {
        case .emptyMessages:
            "At least one message is required."
        }
    }
}

actor MockLLMProvider: LLMProvider {
    typealias Responder = @Sendable ([LLMMessage], LLMOptions) -> LLMCompletion

    let identifier: String

    private let responder: Responder
    private var receivedRequests: [[LLMMessage]] = []

    init(identifier: String = "mock", responder: @escaping Responder = MockLLMProvider.defaultResponder) {
        self.identifier = identifier
        self.responder = responder
    }

    func chat(messages: [LLMMessage], options: LLMOptions = .default) async throws -> LLMCompletion {
        guard !messages.isEmpty else {
            throw LLMProviderError.emptyMessages
        }

        receivedRequests.append(messages)
        return responder(messages, options)
    }

    func toolCall(
        messages: [LLMMessage],
        tools: [LLMTool],
        options: LLMOptions = .default
    ) async throws -> LLMToolResult {
        let completion = try await chat(messages: messages, options: options)
        return LLMToolResult(toolCalls: [], assistantMessage: completion.message)
    }

    func stream(
        messages: [LLMMessage],
        tools: [LLMTool]? = nil,
        options: LLMOptions = .default
    ) async throws -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let completion = try await chat(messages: messages, options: options)
        return AsyncThrowingStream { continuation in
            for token in completion.message.content.split(separator: " ") {
                continuation.yield(.textDelta(String(token)))
            }
            continuation.yield(.completed(completion))
            continuation.finish()
        }
    }

    func requestCount() -> Int {
        receivedRequests.count
    }

    nonisolated private static func defaultResponder(messages: [LLMMessage], _: LLMOptions) -> LLMCompletion {
        let latestUserMessage = messages.last(where: { $0.role == .user })?.content ?? ""
        let reply = "Mock reply: \(latestUserMessage)"
        return LLMCompletion(
            message: LLMMessage(role: .assistant, content: reply),
            stopReason: .completed,
            usage: LLMUsage(promptTokens: max(1, latestUserMessage.count / 4), completionTokens: max(1, reply.count / 4))
        )
    }
}
