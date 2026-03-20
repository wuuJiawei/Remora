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
            terminalTranscriptLineCount: 120
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
                terminalTranscriptLineCount: 80
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

    private func makeDependencies(suffix: String) throws -> (store: AISettingsStore, cleanup: () -> Void) {
        let suiteName = "terminal-ai-coordinator-\(suffix)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let credentialsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terminal-ai-coordinator-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        let credentialStore = CredentialStore(baseDirectoryURL: credentialsDirectory)
        let store = AISettingsStore(defaults: defaults, credentialStore: credentialStore)

        return (
            store,
            {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: credentialsDirectory)
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
