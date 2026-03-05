import Foundation
import Testing
@testable import RemoraApp

struct AppSettingsTests {
    @Test
    func aiEnabledDefaultsToTrueWhenUnset() {
        let defaultsName = "remora.ai.enabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        #expect(AppSettings.resolvedAIEnabled(defaults: defaults) == true)
        defaults.set(false, forKey: AppSettings.aiEnabledKey)
        #expect(AppSettings.resolvedAIEnabled(defaults: defaults) == false)
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
        #expect(AppSettings.clampedServerMetricsActiveRefreshSeconds(-1) == 2)
        #expect(AppSettings.clampedServerMetricsActiveRefreshSeconds(100) == 30)

        #expect(AppSettings.clampedServerMetricsInactiveRefreshSeconds(1) == 4)
        #expect(AppSettings.clampedServerMetricsInactiveRefreshSeconds(999) == 90)

        #expect(AppSettings.clampedServerMetricsMaxConcurrentFetches(0) == 1)
        #expect(AppSettings.clampedServerMetricsMaxConcurrentFetches(99) == 6)
    }

    @Test
    func aiSettingsResolveDefaultsAndClampRanges() {
        #expect(AppSettings.resolvedAIProvider(from: nil) == .openAI)
        #expect(AppSettings.resolvedAIProvider(from: "unknown-provider") == .openAI)
        #expect(AppSettings.resolvedAIProvider(from: "anthropic") == .anthropic)

        #expect(AppSettings.defaultAIModelID(for: .openAI) == "gpt-4.1")
        #expect(AppSettings.defaultAIModelDisplayName(for: .openAI) == "GPT-4.1")

        #expect(AppSettings.clampedAITemperature(-10) == 0.0)
        #expect(AppSettings.clampedAITemperature(10) == 2.0)

        #expect(AppSettings.clampedAIMaxOutputTokens(1) == 256)
        #expect(AppSettings.clampedAIMaxOutputTokens(99_999) == 8_192)
    }

    @Test
    func aiApiFormatAndEndpointAreNormalized() {
        #expect(AppSettings.resolvedAIAPIFormat(from: nil) == .openAIResponses)
        #expect(AppSettings.resolvedAIAPIFormat(from: "invalid") == .openAIResponses)
        #expect(AppSettings.resolvedAIAPIFormat(from: "anthropic_messages") == .anthropicMessages)

        #expect(
            AppSettings.defaultAIEndpointURL(for: .openAI, format: .openAIResponses)
                == "https://api.openai.com/v1"
        )
        #expect(
            AppSettings.defaultAIEndpointURL(for: .anthropic, format: .anthropicMessages)
                == "https://api.anthropic.com"
        )
        #expect(
            AppSettings.defaultAIEndpointURL(for: .gemini, format: .geminiGenerateContent)
                == "https://generativelanguage.googleapis.com"
        )

        #expect(
            AppSettings.normalizedAIEndpointURL("  https://api.openai.com/v1/  ")
                == "https://api.openai.com/v1"
        )
    }
}
