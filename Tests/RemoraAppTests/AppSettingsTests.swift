import Foundation
import Testing
@testable import RemoraApp

struct AppSettingsTests {
    @MainActor
    @Test
    func appPreferencesPersistToJsonFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-app-preferences-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("settings.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let preferences = AppPreferences(fileURL: fileURL)
        preferences.set(AppAppearanceMode.dark.rawValue, for: \.appearanceModeRawValue)
        preferences.set("sk-test-123", for: \.aiAPIKey)

        let rawText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(rawText.contains(AppAppearanceMode.dark.rawValue))
        #expect(rawText.contains("sk-test-123"))

        let reloaded = AppPreferences(fileURL: fileURL)
        #expect(reloaded.value(for: \.appearanceModeRawValue) == AppAppearanceMode.dark.rawValue)
        #expect(reloaded.value(for: \.aiAPIKey) == "sk-test-123")
    }

    @Test
    func resolvedDownloadDirectoryUsesProvidedWritableDirectory() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-app-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let resolved = AppSettings.resolvedDownloadDirectoryURL(from: tempDirectory.path)
        func normalizePath(_ path: String) -> String {
            let standardized = NSString(string: path).standardizingPath
            if standardized.hasSuffix("/") && standardized.count > 1 {
                return String(standardized.dropLast())
            }
            return standardized
        }
        let resolvedPath = normalizePath(resolved.path)
        let expectedPath = normalizePath(tempDirectory.path)
        #expect(resolvedPath == expectedPath)
    }

    @Test
    func resolvedDownloadDirectoryFallsBackWhenPathInvalid() {
        let invalidPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-app-settings-missing-\(UUID().uuidString)")
            .path

        let resolved = AppSettings.resolvedDownloadDirectoryURL(from: invalidPath)
        #expect(resolved.path != invalidPath)
        #expect(AppSettings.isWritableDirectory(resolved))
    }

    @Test
    func metricsSettingsAreClampedIntoSafeRanges() {
        #expect(AppSettings.defaultServerMetricsActiveRefreshSeconds == 1)
        #expect(AppSettings.defaultServerMetricsInactiveRefreshSeconds == 1)
        #expect(AppSettings.clampedServerMetricsActiveRefreshSeconds(-1) == 1)
        #expect(AppSettings.clampedServerMetricsActiveRefreshSeconds(100) == 30)

        #expect(AppSettings.clampedServerMetricsInactiveRefreshSeconds(0) == 1)
        #expect(AppSettings.clampedServerMetricsInactiveRefreshSeconds(999) == 90)

        #expect(AppSettings.clampedServerMetricsMaxConcurrentFetches(0) == 1)
        #expect(AppSettings.clampedServerMetricsMaxConcurrentFetches(99) == 6)
    }

    @Test
    func aiTranscriptSettingsAreClampedIntoSafeRanges() {
        #expect(AppSettings.defaultAITerminalTranscriptLineCount == 120)
        #expect(AppSettings.clampedAITerminalTranscriptLineCount(0) == 20)
        #expect(AppSettings.clampedAITerminalTranscriptLineCount(999) == 400)
    }

    @Test
    func aiProviderDefaultsStayStable() {
        #expect(AIProviderOption.resolved(from: "unknown") == .openAI)
        #expect(AIProviderOption.custom.defaultAPIFormat == .openAICompatible)
        #expect(AIProviderOption.anthropic.defaultAPIFormat == .claudeCompatible)
        #expect(AIProviderOption.openRouter.defaultBaseURL == "https://openrouter.ai/api/v1")
        #expect(AIProviderOption.ollama.defaultBaseURL == "http://localhost:11434/v1")
        #expect(!AIProviderOption.deepSeek.suggestedModels.isEmpty)
        #expect(AppSettings.defaultAIModel == "gpt-5.4")
        #expect(AIProviderOption.openAI.suggestedModels.contains(where: { $0.id == "gpt-5.4" }))
        #expect(AIProviderOption.openAI.suggestedModels.contains(where: { $0.id == "gpt-5-codex" }))
        #expect(AIProviderOption.anthropic.suggestedModels.contains(where: { $0.id == "claude-sonnet-4-5" }))
        #expect(AIProviderOption.qwen.suggestedModels.contains(where: { $0.id == "qwen3.5-plus" }))
        #expect(AIProviderOption.deepSeek.suggestedModels.contains(where: { $0.displayName.contains("V3.2") }))
        #expect(AppSettings.defaultAILanguage == AILanguageOption.system.rawValue)
        #expect(AppSettings.defaultAIRequireRunConfirmation == true)
    }
}
