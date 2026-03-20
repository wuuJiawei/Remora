import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

@MainActor
@Suite(.serialized)
struct TerminalAIAssistantCoordinatorTests {
    @Test
    func disabledStateBlocksSubmission() async throws {
        let dependencies = try makeDependencies(suffix: "disabled")
        defer { dependencies.cleanup() }

        let disabledSettings = AISettingsValue(
            isEnabled: false,
            provider: .openAI,
            apiFormat: .openAICompatible,
            baseURL: AIProviderOption.openAI.defaultBaseURL,
            model: "gpt-4.1-mini",
            smartAssistEnabled: true,
            includeWorkingDirectory: true,
            includeTranscript: true,
            terminalTranscriptLineCount: 120,
            language: .system,
            requireRunConfirmation: true
        )
        dependencies.store.save(disabledSettings)
        await dependencies.store.setAPIKey("sk-test")

        let service = MockTerminalAIResponder()
        let coordinator = TerminalAIAssistantCoordinator(
            service: service,
            settingsStore: dependencies.store,
            runtimeSnapshot: { .init(sessionMode: "Local", hostLabel: nil, workingDirectory: "/tmp", transcript: "") }
        )
        coordinator.bind(to: UUID())

        do {
            try await coordinator.submit("Explain this")
            Issue.record("Expected disabled AI submission to throw.")
        } catch let error as TerminalAIAssistantCoordinatorError {
            #expect(error == .aiDisabled)
        }
    }

    @Test
    func sessionHistoryIsIsolatedPerSession() async throws {
        let dependencies = try makeDependencies(suffix: "history")
        defer { dependencies.cleanup() }

        await dependencies.store.setAPIKey("sk-test")
        let service = MockTerminalAIResponder()
        await service.enqueue(.init(summary: "First answer", commands: [], warnings: []))
        await service.enqueue(.init(summary: "Second answer", commands: [], warnings: []))

        let coordinator = TerminalAIAssistantCoordinator(
            service: service,
            settingsStore: dependencies.store,
            runtimeSnapshot: { .init(sessionMode: "SSH", hostLabel: "box", workingDirectory: "/srv/app", transcript: "tail") }
        )

        let firstSession = UUID()
        let secondSession = UUID()

        coordinator.bind(to: firstSession)
        try await coordinator.submit("First prompt")
        #expect(coordinator.messages.count == 2)
        #expect(coordinator.messages.last?.response?.summary == "First answer")

        coordinator.bind(to: secondSession)
        #expect(coordinator.messages.isEmpty)
        try await coordinator.submit("Second prompt")
        #expect(coordinator.messages.count == 2)
        #expect(coordinator.messages.last?.response?.summary == "Second answer")

        coordinator.bind(to: firstSession)
        #expect(coordinator.messages.count == 2)
        #expect(coordinator.messages.first?.prompt == "First prompt")
        #expect(coordinator.messages.last?.response?.summary == "First answer")
    }

    @Test
    func submitBuildsContextFromRuntimeSnapshotAndSettings() async throws {
        let dependencies = try makeDependencies(suffix: "context")
        defer { dependencies.cleanup() }

        dependencies.store.save(
            AISettingsValue(
                isEnabled: true,
                provider: .custom,
                apiFormat: .claudeCompatible,
                baseURL: "https://llm.example.com",
                model: "claude-custom",
                smartAssistEnabled: true,
                includeWorkingDirectory: true,
                includeTranscript: true,
                terminalTranscriptLineCount: 80,
                language: .simplifiedChinese,
                requireRunConfirmation: true
            )
        )
        await dependencies.store.setAPIKey("sk-custom")

        let service = MockTerminalAIResponder(response: .init(summary: "ok", commands: [], warnings: []))
        let coordinator = TerminalAIAssistantCoordinator(
            service: service,
            settingsStore: dependencies.store,
            runtimeSnapshot: {
                .init(
                    sessionMode: "SSH",
                    hostLabel: "prod-api",
                    workingDirectory: "/var/www/app",
                    transcript: "permission denied\ncommand not found"
                )
            }
        )
        coordinator.bind(to: UUID())

        try await coordinator.submit("Fix this deployment issue")

        let request = try #require(await service.lastContext)
        let configuration = try #require(await service.lastConfiguration)
        #expect(request.userPrompt == "Fix this deployment issue")
        #expect(request.sessionMode == "SSH")
        #expect(request.hostLabel == "prod-api")
        #expect(request.workingDirectory == "/var/www/app")
        #expect(request.transcript?.contains("permission denied") == true)
        #expect(request.preferredResponseLanguage == "Simplified Chinese")
        #expect(configuration.apiFormat == .claudeCompatible)
        #expect(configuration.baseURL == "https://llm.example.com")
        #expect(configuration.model == "claude-custom")
        #expect(configuration.apiKey == "sk-custom")
    }

    @Test
    func refreshSmartAssistDetectsCommonTerminalFailures() async throws {
        let dependencies = try makeDependencies(suffix: "assist")
        defer { dependencies.cleanup() }

        let coordinator = TerminalAIAssistantCoordinator(
            service: MockTerminalAIResponder(response: .init(summary: "ok", commands: [], warnings: [])),
            settingsStore: dependencies.store,
            runtimeSnapshot: {
                .init(
                    sessionMode: "SSH",
                    hostLabel: "box",
                    workingDirectory: "/srv/app",
                    transcript: "bash: deploy.sh: Permission denied"
                )
            }
        )

        coordinator.refreshSmartAssist()

        #expect(coordinator.smartAssist?.kind == .permissionDenied)
        #expect(coordinator.smartAssist?.prompt.contains("permission denied") == true)
    }

    @Test
    func submitShowsThinkingPlaceholderBeforeAssistantResponseArrives() async throws {
        let dependencies = try makeDependencies(suffix: "thinking")
        defer { dependencies.cleanup() }

        await dependencies.store.setAPIKey("sk-test")
        let service = DelayedMockTerminalAIResponder(
            delayNanoseconds: 150_000_000,
            response: .init(summary: "Eventually ready", commands: [], warnings: [])
        )
        let coordinator = TerminalAIAssistantCoordinator(
            service: service,
            settingsStore: dependencies.store,
            runtimeSnapshot: { .init(sessionMode: "Local", hostLabel: nil, workingDirectory: "/tmp", transcript: "") },
            streamingChunkDelayNanoseconds: 5_000_000
        )
        coordinator.bind(to: UUID())

        let task = Task {
            try await coordinator.submit("Explain this")
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(coordinator.messages.count == 2)
        #expect(coordinator.messages.last?.isThinking == true)
        #expect(coordinator.messages.last?.response == nil)

        _ = await task.result
    }

    @Test
    func submitStreamsAssistantSummaryBeforeFinalStructuredResponse() async throws {
        let dependencies = try makeDependencies(suffix: "stream")
        defer { dependencies.cleanup() }

        await dependencies.store.setAPIKey("sk-test")
        let service = MockTerminalAIResponder(
            response: .init(
                summary: "This is a longer streamed assistant summary for verification.",
                commands: [],
                warnings: []
            )
        )
        let coordinator = TerminalAIAssistantCoordinator(
            service: service,
            settingsStore: dependencies.store,
            runtimeSnapshot: { .init(sessionMode: "Local", hostLabel: nil, workingDirectory: "/tmp", transcript: "") },
            streamingChunkDelayNanoseconds: 25_000_000
        )
        coordinator.bind(to: UUID())

        let task = Task {
            try await coordinator.submit("Explain this")
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 90_000_000)

        #expect(coordinator.messages.last?.isStreaming == true)
        #expect((coordinator.messages.last?.streamedText ?? "").isEmpty == false)
        #expect(coordinator.messages.last?.response == nil)

        _ = await task.result
        #expect(coordinator.messages.last?.response?.summary == "This is a longer streamed assistant summary for verification.")
    }

    @Test
    func submitQueuesLaterPromptsWhileResponseIsRunning() async throws {
        let dependencies = try makeDependencies(suffix: "queue")
        defer { dependencies.cleanup() }

        await dependencies.store.setAPIKey("sk-test")
        let service = DelayedSequenceTerminalAIResponder(
            delays: [180_000_000, 10_000_000],
            responses: [
                .init(summary: "First done", commands: [], warnings: []),
                .init(summary: "Second done", commands: [], warnings: []),
            ]
        )
        let coordinator = TerminalAIAssistantCoordinator(
            service: service,
            settingsStore: dependencies.store,
            runtimeSnapshot: { .init(sessionMode: "Local", hostLabel: nil, workingDirectory: "/tmp", transcript: "") },
            streamingChunkDelayNanoseconds: 0
        )
        coordinator.bind(to: UUID())

        let firstTask = Task { try await coordinator.submit("first") }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 40_000_000)

        try await coordinator.submit("second")
        #expect(coordinator.queuedPrompts.count == 1)
        #expect(coordinator.queuedPrompts.first?.text == "second")

        _ = await firstTask.result
        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(coordinator.queuedPrompts.isEmpty)
        #expect(coordinator.messages.contains(where: { $0.prompt == "second" }))
        #expect(coordinator.messages.last?.response?.summary == "Second done")
    }

    @Test
    func submitCompactsOlderConversationWhenHistoryGetsLarge() async throws {
        let dependencies = try makeDependencies(suffix: "compact")
        defer { dependencies.cleanup() }

        await dependencies.store.setAPIKey("sk-test")
        let service = MockTerminalAIResponder(response: .init(summary: "ok", commands: [], warnings: []))
        let coordinator = TerminalAIAssistantCoordinator(
            service: service,
            settingsStore: dependencies.store,
            runtimeSnapshot: { .init(sessionMode: "Local", hostLabel: nil, workingDirectory: "/tmp", transcript: String(repeating: "log line\n", count: 20)) },
            streamingChunkDelayNanoseconds: 0,
            conversationCharacterBudget: 240
        )
        coordinator.bind(to: UUID())

        coordinator.debugReplaceMessagesForTesting([
            .init(prompt: String(repeating: "first prompt ", count: 20)),
            .init(response: .init(summary: String(repeating: "first response ", count: 20), commands: [], warnings: [])),
            .init(prompt: String(repeating: "second prompt ", count: 20)),
            .init(response: .init(summary: String(repeating: "second response ", count: 20), commands: [], warnings: [])),
        ])

        try await coordinator.submit("latest question")

        let request = try #require(await service.lastContext)
        #expect(coordinator.messages.contains(where: { $0.kind == .summary }))
        #expect(request.conversationContext?.contains("Compacted earlier conversation") == true)
        #expect(request.conversationContext?.contains("Summary Turn") == true)
    }

    private func makeDependencies(suffix: String) throws -> (store: AISettingsStore, cleanup: () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terminal-ai-coordinator-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        let preferences = AppPreferences(fileURL: root.appendingPathComponent("settings.json"))
        let store = AISettingsStore(preferences: preferences)

        return (
            store,
            {
                try? FileManager.default.removeItem(at: root)
            }
        )
    }
}

private actor MockTerminalAIResponder: TerminalAIResponding {
    private var queuedResponses: [TerminalAIResponse] = []
    private(set) var lastContext: TerminalAIRequestContext?
    private(set) var lastConfiguration: TerminalAIServiceConfiguration?

    init(response: TerminalAIResponse? = nil) {
        if let response {
            queuedResponses = [response]
        }
    }

    func enqueue(_ response: TerminalAIResponse) {
        queuedResponses.append(response)
    }

    func respond(
        to context: TerminalAIRequestContext,
        configuration: TerminalAIServiceConfiguration
    ) async throws -> TerminalAIResponse {
        lastContext = context
        lastConfiguration = configuration
        if !queuedResponses.isEmpty {
            return queuedResponses.removeFirst()
        }
        return TerminalAIResponse(summary: "default", commands: [], warnings: [])
    }
}

private actor DelayedMockTerminalAIResponder: TerminalAIResponding {
    let delayNanoseconds: UInt64
    let response: TerminalAIResponse

    init(delayNanoseconds: UInt64, response: TerminalAIResponse) {
        self.delayNanoseconds = delayNanoseconds
        self.response = response
    }

    func respond(
        to context: TerminalAIRequestContext,
        configuration: TerminalAIServiceConfiguration
    ) async throws -> TerminalAIResponse {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return response
    }
}

private actor DelayedSequenceTerminalAIResponder: TerminalAIResponding {
    private var delays: [UInt64]
    private var responses: [TerminalAIResponse]

    init(delays: [UInt64], responses: [TerminalAIResponse]) {
        self.delays = delays
        self.responses = responses
    }

    func respond(
        to context: TerminalAIRequestContext,
        configuration: TerminalAIServiceConfiguration
    ) async throws -> TerminalAIResponse {
        let delay = delays.isEmpty ? 0 : delays.removeFirst()
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        return responses.isEmpty ? .init(summary: "default", commands: [], warnings: []) : responses.removeFirst()
    }
}
