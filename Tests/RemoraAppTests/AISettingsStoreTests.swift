import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

struct AISettingsStoreTests {
    @Test
    func loadReturnsDefaultsWhenStorageIsEmpty() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-settings-store-\(UUID().uuidString)", isDirectory: true)
        let preferences = AppPreferences(fileURL: root.appendingPathComponent("settings.json"))
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = AISettingsStore(preferences: preferences)

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
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-settings-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("settings.json")
        let preferences = AppPreferences(fileURL: fileURL)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = AISettingsStore(preferences: preferences)

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

        let rawText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(rawText.contains("llm.example.com"))
        #expect(rawText.contains("claude-compat-model"))
    }

    @Test
    func apiKeyIsStoredInSettingsFileAndCanBeCleared() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-settings-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("settings.json")
        let preferences = AppPreferences(fileURL: fileURL)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = AISettingsStore(preferences: preferences)

        await store.setAPIKey("sk-test-123")
        #expect(await store.apiKey() == "sk-test-123")
        let savedText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(savedText.contains("sk-test-123"))

        await store.setAPIKey("   ")
        #expect(await store.apiKey() == nil)
        let clearedText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!clearedText.contains("sk-test-123"))
    }
}
