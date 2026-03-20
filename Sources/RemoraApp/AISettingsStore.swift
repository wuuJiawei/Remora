import Foundation
import RemoraCore

final class AISettingsStore: @unchecked Sendable {
    private let preferences: AppPreferences

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences
    }

    func load() -> AISettingsValue {
        let provider = AIProviderOption.resolved(
            from: preferences.value(for: \.aiProviderRawValue)
        )
        let apiFormat = AIAPIFormatOption.resolved(
            from: preferences.value(for: \.aiAPIFormatRawValue)
        )
        let baseURL = normalizedStoredString(preferences.value(for: \.aiBaseURL)) ?? provider.defaultBaseURL
        let model = normalizedStoredString(preferences.value(for: \.aiModel)) ?? AppSettings.defaultAIModel
        let language = AILanguageOption.resolved(
            from: preferences.value(for: \.aiLanguageRawValue)
        )

        return AISettingsValue(
            isEnabled: preferences.value(for: \.aiEnabled),
            provider: provider,
            apiFormat: apiFormat,
            baseURL: baseURL,
            model: model,
            smartAssistEnabled: preferences.value(for: \.aiSmartAssistEnabled),
            includeWorkingDirectory: preferences.value(for: \.aiIncludeWorkingDirectory),
            includeTranscript: preferences.value(for: \.aiIncludeTranscript),
            terminalTranscriptLineCount: AppSettings.clampedAITerminalTranscriptLineCount(preferences.value(for: \.aiTranscriptLineCount)),
            language: language,
            requireRunConfirmation: preferences.value(for: \.aiRequireRunConfirmation)
        )
    }

    func save(_ value: AISettingsValue) {
        preferences.set(value.isEnabled, for: \.aiEnabled)
        preferences.set(value.provider.rawValue, for: \.aiProviderRawValue)
        preferences.set(value.apiFormat.rawValue, for: \.aiAPIFormatRawValue)
        preferences.set(normalizedStoredString(value.baseURL) ?? value.provider.defaultBaseURL, for: \.aiBaseURL)
        preferences.set(normalizedStoredString(value.model) ?? AppSettings.defaultAIModel, for: \.aiModel)
        preferences.set(value.language.rawValue, for: \.aiLanguageRawValue)
        preferences.set(value.smartAssistEnabled, for: \.aiSmartAssistEnabled)
        preferences.set(value.includeWorkingDirectory, for: \.aiIncludeWorkingDirectory)
        preferences.set(value.includeTranscript, for: \.aiIncludeTranscript)
        preferences.set(AppSettings.clampedAITerminalTranscriptLineCount(value.terminalTranscriptLineCount), for: \.aiTranscriptLineCount)
        preferences.set(value.requireRunConfirmation, for: \.aiRequireRunConfirmation)
    }

    func apiKey() async -> String? {
        normalizedStoredString(preferences.value(for: \.aiAPIKey))
    }

    func setAPIKey(_ value: String) async {
        preferences.set(normalizedStoredString(value) ?? "", for: \.aiAPIKey)
    }

    private func normalizedStoredString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
