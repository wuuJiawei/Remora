import Foundation
import RemoraCore

final class AISettingsStore {
    static let apiKeyReference = "settings.ai.apiKey"

    private let defaults: UserDefaults
    private let credentialStore: CredentialStore

    init(defaults: UserDefaults = .standard, credentialStore: CredentialStore = CredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
    }

    func load() -> AISettingsValue {
        let provider = AIProviderOption.resolved(
            from: defaults.string(forKey: AppSettings.aiActiveProviderKey) ?? AppSettings.defaultAIActiveProvider
        )
        let apiFormat = AIAPIFormatOption.resolved(
            from: defaults.string(forKey: AppSettings.aiAPIFormatKey) ?? provider.defaultAPIFormat.rawValue
        )
        let baseURL = normalizedStoredString(defaults.string(forKey: AppSettings.aiBaseURLKey)) ?? provider.defaultBaseURL
        let model = normalizedStoredString(defaults.string(forKey: AppSettings.aiModelKey)) ?? AppSettings.defaultAIModel

        return AISettingsValue(
            isEnabled: defaults.object(forKey: AppSettings.aiEnabledKey) as? Bool ?? AppSettings.defaultAIEnabled,
            provider: provider,
            apiFormat: apiFormat,
            baseURL: baseURL,
            model: model,
            smartAssistEnabled: defaults.object(forKey: AppSettings.aiSmartAssistEnabledKey) as? Bool ?? AppSettings.defaultAISmartAssistEnabled,
            includeWorkingDirectory: defaults.object(forKey: AppSettings.aiIncludeWorkingDirectoryKey) as? Bool ?? AppSettings.defaultAIIncludeWorkingDirectory,
            includeTranscript: defaults.object(forKey: AppSettings.aiIncludeTranscriptKey) as? Bool ?? AppSettings.defaultAIIncludeTranscript,
            terminalTranscriptLineCount: AppSettings.clampedAITerminalTranscriptLineCount(
                defaults.object(forKey: AppSettings.aiTerminalTranscriptLineCountKey) as? Int ?? AppSettings.defaultAITerminalTranscriptLineCount
            )
        )
    }

    func save(_ value: AISettingsValue) {
        defaults.set(value.isEnabled, forKey: AppSettings.aiEnabledKey)
        defaults.set(value.provider.rawValue, forKey: AppSettings.aiActiveProviderKey)
        defaults.set(value.apiFormat.rawValue, forKey: AppSettings.aiAPIFormatKey)
        defaults.set(normalizedStoredString(value.baseURL) ?? value.provider.defaultBaseURL, forKey: AppSettings.aiBaseURLKey)
        defaults.set(normalizedStoredString(value.model) ?? AppSettings.defaultAIModel, forKey: AppSettings.aiModelKey)
        defaults.set(value.smartAssistEnabled, forKey: AppSettings.aiSmartAssistEnabledKey)
        defaults.set(value.includeWorkingDirectory, forKey: AppSettings.aiIncludeWorkingDirectoryKey)
        defaults.set(value.includeTranscript, forKey: AppSettings.aiIncludeTranscriptKey)
        defaults.set(
            AppSettings.clampedAITerminalTranscriptLineCount(value.terminalTranscriptLineCount),
            forKey: AppSettings.aiTerminalTranscriptLineCountKey
        )
    }

    func apiKey() async -> String? {
        await credentialStore.secret(for: Self.apiKeyReference)
    }

    func setAPIKey(_ value: String) async {
        guard let normalized = normalizedStoredString(value) else {
            await credentialStore.removeSecret(for: Self.apiKeyReference)
            return
        }
        await credentialStore.setSecret(normalized, for: Self.apiKeyReference)
    }

    private func normalizedStoredString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
