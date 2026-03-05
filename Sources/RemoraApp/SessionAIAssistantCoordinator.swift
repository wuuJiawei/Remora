import Foundation

struct AISessionMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: LLMRole
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: LLMRole, content: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    var asLLMMessage: LLMMessage {
        LLMMessage(role: role, content: content)
    }
}

enum SessionAIAssistantCoordinatorError: LocalizedError, Equatable, Sendable {
    case sessionNotBound
    case emptyInput
    case aiDisabled

    var errorDescription: String? {
        switch self {
        case .sessionNotBound:
            "Session is not bound for AI assistant."
        case .emptyInput:
            "Input cannot be empty."
        case .aiDisabled:
            "AI features are disabled in Settings."
        }
    }
}

@MainActor
final class SessionAIAssistantCoordinator: ObservableObject {
    @Published private(set) var boundSessionID: UUID?
    @Published private(set) var messages: [AISessionMessage]
    @Published private(set) var isResponding: Bool

    private let provider: any LLMProvider
    private let isAIEnabled: @Sendable () -> Bool
    private var historyBySession: [UUID: [AISessionMessage]]

    init(
        provider: any LLMProvider = MockLLMProvider(),
        isAIEnabled: @escaping @Sendable () -> Bool = {
            AppSettings.resolvedAIEnabled()
        }
    ) {
        self.provider = provider
        self.isAIEnabled = isAIEnabled
        self.boundSessionID = nil
        self.messages = []
        self.isResponding = false
        self.historyBySession = [:]
    }

    func bind(to sessionID: UUID) {
        boundSessionID = sessionID
        messages = historyBySession[sessionID] ?? []
    }

    func sendUserMessage(_ text: String, options: LLMOptions = .default) async throws {
        guard isAIEnabled() else {
            throw SessionAIAssistantCoordinatorError.aiDisabled
        }

        guard let sessionID = boundSessionID else {
            throw SessionAIAssistantCoordinatorError.sessionNotBound
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionAIAssistantCoordinatorError.emptyInput
        }

        let userMessage = AISessionMessage(role: .user, content: trimmed)
        appendMessage(userMessage, for: sessionID)

        let prompt = historyBySession[sessionID, default: []].map(\.asLLMMessage)

        isResponding = true
        defer { isResponding = false }

        let completion = try await provider.chat(messages: prompt, options: options)
        let assistantMessage = AISessionMessage(role: completion.message.role, content: completion.message.content)
        appendMessage(assistantMessage, for: sessionID)
    }

    func clearHistory(for sessionID: UUID) {
        historyBySession.removeValue(forKey: sessionID)
        if boundSessionID == sessionID {
            messages = []
        }
    }

    private func appendMessage(_ message: AISessionMessage, for sessionID: UUID) {
        var history = historyBySession[sessionID, default: []]
        history.append(message)
        historyBySession[sessionID] = history

        if boundSessionID == sessionID {
            messages = history
        }
    }
}
