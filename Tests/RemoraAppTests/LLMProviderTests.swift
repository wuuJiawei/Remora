import Foundation
import Testing
@testable import RemoraApp

struct LLMProviderTests {
    @Test
    func mockProviderSupportsSingleTurnChat() async throws {
        let provider = MockLLMProvider()
        let messages = [
            LLMMessage(role: .system, content: "You are a shell assistant."),
            LLMMessage(role: .user, content: "List the biggest files in this folder")
        ]

        let completion = try await provider.chat(messages: messages, options: .default)

        #expect(completion.message.role == .assistant)
        #expect(completion.message.content.contains("List the biggest files in this folder"))
        #expect(completion.stopReason == .completed)
        #expect(completion.usage.totalTokens > 0)
        #expect(await provider.requestCount() == 1)
    }

    @Test
    func mockProviderStreamYieldsDeltasAndFinalCompletion() async throws {
        let provider = MockLLMProvider()
        let messages = [
            LLMMessage(role: .user, content: "show disk usage")
        ]

        var deltas: [String] = []
        var finalCompletion: LLMCompletion?

        let stream = try await provider.stream(messages: messages, tools: nil, options: .default)
        for try await event in stream {
            switch event {
            case .textDelta(let token):
                deltas.append(token)
            case .completed(let completion):
                finalCompletion = completion
            case .toolCall:
                Issue.record("Mock stream should not emit tool calls in AI-102 baseline")
            }
        }

        #expect(!deltas.isEmpty)
        #expect(finalCompletion?.message.role == .assistant)
        #expect(finalCompletion?.message.content.contains("show disk usage") == true)
    }

    @Test
    func mockProviderThrowsWhenMessagesAreEmpty() async {
        let provider = MockLLMProvider()

        await #expect(throws: LLMProviderError.emptyMessages) {
            _ = try await provider.chat(messages: [], options: .default)
        }
    }
}
