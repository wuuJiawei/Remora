import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

struct AISettingsStoreTests {
    @Test
    func loadReturnsDefaultsWhenStorageIsEmpty() async throws {
        let suiteName = "ai-settings-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let credentialsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-settings-store-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: credentialsDirectory)
        }

        let store = AISettingsStore(
            defaults: defaults,
            credentialStore: CredentialStore(baseDirectoryURL: credentialsDirectory)
        )

        let settings = store.load()

        #expect(settings.isEnabled == AppSettings.defaultAIEnabled)
        #expect(settings.provider == .openAI)
        #expect(settings.apiFormat == .openAICompatible)
        #expect(settings.baseURL == AIProviderOption.openAI.defaultBaseURL)
        #expect(settings.model == AppSettings.defaultAIModel)
        #expect(settings.terminalTranscriptLineCount == AppSettings.defaultAITerminalTranscriptLineCount)
        #expect(settings.language == .system)
        #expect(settings.requireRunConfirmation == true)
        #expect(await store.apiKey() == nil)
    }

    @Test
    func savePersistsSettingsAndClampsTranscriptBudget() async throws {
        let suiteName = "ai-settings-save-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let credentialsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-settings-store-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: credentialsDirectory)
        }

        let store = AISettingsStore(
            defaults: defaults,
            credentialStore: CredentialStore(baseDirectoryURL: credentialsDirectory)
        )

        store.save(
            AISettingsValue(
                isEnabled: true,
                provider: .custom,
                apiFormat: .claudeCompatible,
                baseURL: "https://llm.example.com",
                model: "claude-compat-model",
                smartAssistEnabled: false,
                includeWorkingDirectory: false,
                includeTranscript: true,
                terminalTranscriptLineCount: 999,
                language: .simplifiedChinese,
                requireRunConfirmation: false
            )
        )

        let saved = store.load()

        #expect(saved.provider == .custom)
        #expect(saved.apiFormat == .claudeCompatible)
        #expect(saved.baseURL == "https://llm.example.com")
        #expect(saved.model == "claude-compat-model")
        #expect(saved.smartAssistEnabled == false)
        #expect(saved.includeWorkingDirectory == false)
        #expect(saved.includeTranscript == true)
        #expect(saved.terminalTranscriptLineCount == 400)
        #expect(saved.language == .simplifiedChinese)
        #expect(saved.requireRunConfirmation == false)
    }

    @Test
    func apiKeyIsStoredInCredentialStoreAndCanBeCleared() async throws {
        let suiteName = "ai-settings-key-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let credentialsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-settings-store-\(UUID().uuidString)", isDirectory: true)
        let credentialStore = CredentialStore(baseDirectoryURL: credentialsDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: credentialsDirectory)
        }

        let store = AISettingsStore(defaults: defaults, credentialStore: credentialStore)

        await store.setAPIKey("sk-test-123")
        #expect(await store.apiKey() == "sk-test-123")
        #expect(await credentialStore.secret(for: AISettingsStore.apiKeyReference) == "sk-test-123")

        await store.setAPIKey("   ")
        #expect(await store.apiKey() == nil)
        #expect(await credentialStore.secret(for: AISettingsStore.apiKeyReference) == nil)
    }
}
