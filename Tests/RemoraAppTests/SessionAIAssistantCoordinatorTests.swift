import Foundation
import Testing
@testable import RemoraApp

@MainActor
struct SessionAIAssistantCoordinatorTests {
    @Test
    func maintainsSeparateMessageHistoriesPerSession() async throws {
        let coordinator = SessionAIAssistantCoordinator(provider: MockLLMProvider())
        let sessionA = UUID()
        let sessionB = UUID()

        coordinator.bind(to: sessionA)
        try await coordinator.sendUserMessage("Check nginx logs")

        #expect(coordinator.boundSessionID == sessionA)
        #expect(coordinator.messages.count == 2)
        #expect(coordinator.messages[0].content == "Check nginx logs")

        coordinator.bind(to: sessionB)
        #expect(coordinator.messages.isEmpty)

        try await coordinator.sendUserMessage("Show disk usage")
        #expect(coordinator.messages.count == 2)
        #expect(coordinator.messages[0].content == "Show disk usage")

        coordinator.bind(to: sessionA)
        #expect(coordinator.messages.count == 2)
        #expect(coordinator.messages[0].content == "Check nginx logs")
        #expect(coordinator.messages[1].content.contains("Mock reply:"))
    }

    @Test
    func sendMessageFailsWhenSessionNotBound() async {
        let coordinator = SessionAIAssistantCoordinator(provider: MockLLMProvider())

        await #expect(throws: SessionAIAssistantCoordinatorError.sessionNotBound) {
            try await coordinator.sendUserMessage("whoami")
        }
    }

    @Test
    func sendMessageRejectsEmptyInput() async {
        let coordinator = SessionAIAssistantCoordinator(provider: MockLLMProvider())
        coordinator.bind(to: UUID())

        await #expect(throws: SessionAIAssistantCoordinatorError.emptyInput) {
            try await coordinator.sendUserMessage("   ")
        }
    }

    @Test
    func sendMessageFailsWhenAIDisabled() async {
        let coordinator = SessionAIAssistantCoordinator(
            provider: MockLLMProvider(),
            isAIEnabled: { false }
        )
        coordinator.bind(to: UUID())

        await #expect(throws: SessionAIAssistantCoordinatorError.aiDisabled) {
            try await coordinator.sendUserMessage("whoami")
        }
    }
}
