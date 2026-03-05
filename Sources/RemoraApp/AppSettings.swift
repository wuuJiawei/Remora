import Foundation

enum AppSettings {
    static let downloadDirectoryPathKey = "settings.fileManager.downloadDirectoryPath"
    static let appearanceModeKey = "settings.appearance.mode"
    static let languageModeKey = "settings.language.mode"
    static let keyboardShortcutsStorageKey = "settings.keyboardShortcuts.bindings"
    static let terminalWordSeparatorsKey = "settings.terminal.wordSeparators"
    static let terminalScrollSensitivityKey = "settings.terminal.scrollSensitivity"
    static let terminalFastScrollSensitivityKey = "settings.terminal.fastScrollSensitivity"
    static let terminalScrollOnUserInputKey = "settings.terminal.scrollOnUserInput"
    static let serverMetricsActiveRefreshSecondsKey = "settings.metrics.activeRefreshSeconds"
    static let serverMetricsInactiveRefreshSecondsKey = "settings.metrics.inactiveRefreshSeconds"
    static let serverMetricsMaxConcurrentFetchesKey = "settings.metrics.maxConcurrentFetches"
    static let aiProviderKey = "settings.ai.provider"
    static let aiEnabledKey = "settings.ai.enabled"
    static let aiProviderDisplayNameKey = "settings.ai.provider.displayName"
    static let aiProviderNoteKey = "settings.ai.provider.note"
    static let aiProviderWebsiteURLKey = "settings.ai.provider.websiteURL"
    static let aiAPIKeyKey = "settings.ai.apiKey"
    static let aiAPIFormatKey = "settings.ai.api.format"
    static let aiEndpointURLKey = "settings.ai.api.endpointURL"
    static let aiModelIDKey = "settings.ai.model.id"
    static let aiModelDisplayNameKey = "settings.ai.model.displayName"
    static let aiProviderConfigJSONKey = "settings.ai.provider.configJSON"
    static let aiTemperatureKey = "settings.ai.temperature"
    static let aiMaxOutputTokensKey = "settings.ai.maxOutputTokens"
    static let aiStreamingEnabledKey = "settings.ai.streamingEnabled"

    static let defaultServerMetricsActiveRefreshSeconds = 4
    static let defaultServerMetricsInactiveRefreshSeconds = 10
    static let defaultServerMetricsMaxConcurrentFetches = 2
    static let defaultAIProvider: AIProviderOption = .openAI
    static let defaultAIEnabled = true
    static let defaultAIProviderDisplayName = "OpenAI Official"
    static let defaultAIProviderNote = ""
    static let defaultAIProviderWebsiteURL = ""
    static let defaultAIAPIKey = ""
    static let defaultAIAPIFormat = defaultAIProvider.defaultAPIFormat
    static let defaultAIEndpointURL = defaultAIProvider.defaultEndpoint(for: defaultAIAPIFormat)
    static let defaultAIModelID = defaultAIProvider.defaultModel.id
    static let defaultAIModelDisplayName = defaultAIProvider.defaultModel.displayName
    static let defaultAIProviderConfigJSON = "{\n  \"env\": {\n    \"API_TIMEOUT_MS\": \"300000\"\n  }\n}"
    static let defaultAITemperature = 0.2
    static let defaultAIMaxOutputTokens = 2_048
    static let defaultAIStreamingEnabled = true
    static let defaultTerminalWordSeparators = " ()[]{}'\"`"
    static let defaultTerminalScrollSensitivity = 1.0
    static let defaultTerminalFastScrollSensitivity = 5.0

    static func resolvedDownloadDirectoryURL(
        from rawPath: String?,
        fileManager: FileManager = .default
    ) -> URL {
        if let rawPath {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidate = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
                if isWritableDirectory(candidate, fileManager: fileManager) {
                    return candidate
                }
            }
        }
        return defaultDownloadDirectoryURL(fileManager: fileManager)
    }

    static func defaultDownloadDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            if !fileManager.fileExists(atPath: downloads.path) {
                try? fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
            }
            if isWritableDirectory(downloads, fileManager: fileManager) {
                return downloads
            }
        }

        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        if isWritableDirectory(current, fileManager: fileManager) {
            return current
        }

        let home = fileManager.homeDirectoryForCurrentUser
        if isWritableDirectory(home, fileManager: fileManager) {
            return home
        }

        return fileManager.homeDirectoryForCurrentUser
    }

    static func isWritableDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fileManager.isWritableFile(atPath: url.path)
    }

    static func clampedServerMetricsActiveRefreshSeconds(_ value: Int) -> Int {
        min(max(value, 2), 30)
    }

    static func clampedServerMetricsInactiveRefreshSeconds(_ value: Int) -> Int {
        min(max(value, 4), 90)
    }

    static func clampedServerMetricsMaxConcurrentFetches(_ value: Int) -> Int {
        min(max(value, 1), 6)
    }

    static func resolvedAIProvider(from rawValue: String?) -> AIProviderOption {
        guard let rawValue else { return defaultAIProvider }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultAIProvider }
        return AIProviderOption.resolved(from: trimmed)
    }

    static func resolvedAIEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: aiEnabledKey) == nil {
            return defaultAIEnabled
        }
        return defaults.bool(forKey: aiEnabledKey)
    }

    static func defaultAIModelID(for provider: AIProviderOption) -> String {
        provider.defaultModel.id
    }

    static func defaultAIModelDisplayName(for provider: AIProviderOption) -> String {
        provider.defaultModel.displayName
    }

    static func defaultAIProviderDisplayName(for provider: AIProviderOption) -> String {
        "\(provider.title) Official"
    }

    static func resolvedAIAPIFormat(from rawValue: String?) -> AIAPIFormatOption {
        guard let rawValue else { return defaultAIAPIFormat }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultAIAPIFormat }
        return AIAPIFormatOption.resolved(from: trimmed)
    }

    static func defaultAIAPIFormat(for provider: AIProviderOption) -> AIAPIFormatOption {
        provider.defaultAPIFormat
    }

    static func defaultAIEndpointURL(for provider: AIProviderOption, format: AIAPIFormatOption? = nil) -> String {
        provider.defaultEndpoint(for: format)
    }

    static func normalizedAIEndpointURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    static func clampedAITemperature(_ value: Double) -> Double {
        min(max(value, 0.0), 2.0)
    }

    static func clampedAIMaxOutputTokens(_ value: Int) -> Int {
        min(max(value, 256), 8_192)
    }

    static func resolvedTerminalWordSeparators(defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: terminalWordSeparatorsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultTerminalWordSeparators : raw
    }

    static func resolvedTerminalScrollSensitivity(defaults: UserDefaults = .standard) -> Double {
        let raw = defaults.object(forKey: terminalScrollSensitivityKey) as? Double ?? defaultTerminalScrollSensitivity
        return clampedTerminalScrollSensitivity(raw)
    }

    static func resolvedTerminalFastScrollSensitivity(defaults: UserDefaults = .standard) -> Double {
        let raw = defaults.object(forKey: terminalFastScrollSensitivityKey) as? Double ?? defaultTerminalFastScrollSensitivity
        return clampedTerminalScrollSensitivity(raw)
    }

    static func resolvedTerminalScrollOnUserInput(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: terminalScrollOnUserInputKey) == nil {
            return true
        }
        return defaults.bool(forKey: terminalScrollOnUserInputKey)
    }

    static func clampedTerminalScrollSensitivity(_ value: Double) -> Double {
        min(max(value, 0.1), 12.0)
    }
}

enum AppLinks {
    static let repositoryURL = URL(string: "https://github.com/wuuJiawei/Remora")!
    static let issuesURL = URL(string: "https://github.com/wuuJiawei/Remora/issues")!
}

extension Notification.Name {
    static let remoraDownloadDirectoryDidChange = Notification.Name("remora.downloadDirectoryDidChange")
    static let remoraOpenDownloadDirectorySetting = Notification.Name("remora.openDownloadDirectorySetting")
    static let remoraOpenSettingsCommand = Notification.Name("remora.command.openSettings")
    static let remoraToggleSidebarCommand = Notification.Name("remora.command.toggleSidebar")
    static let remoraNewSSHConnectionCommand = Notification.Name("remora.command.newSSHConnection")
    static let remoraImportConnectionsCommand = Notification.Name("remora.command.importConnections")
    static let remoraExportConnectionsCommand = Notification.Name("remora.command.exportConnections")
}
