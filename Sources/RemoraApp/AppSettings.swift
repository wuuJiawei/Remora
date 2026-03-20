import Foundation

enum AppSettings {
    static let downloadDirectoryPathKey = "settings.fileManager.downloadDirectoryPath"
    static let appearanceModeKey = "settings.appearance.mode"
    static let languageModeKey = "settings.language.mode"
    static let keyboardShortcutsStorageKey = "settings.keyboardShortcuts.bindings"
    static let aiEnabledKey = "settings.ai.enabled"
    static let aiActiveProviderKey = "settings.ai.activeProvider"
    static let aiAPIFormatKey = "settings.ai.apiFormat"
    static let aiBaseURLKey = "settings.ai.baseURL"
    static let aiModelKey = "settings.ai.model"
    static let aiSmartAssistEnabledKey = "settings.ai.smartAssistEnabled"
    static let aiIncludeWorkingDirectoryKey = "settings.ai.includeWorkingDirectory"
    static let aiIncludeTranscriptKey = "settings.ai.includeTranscript"
    static let aiTerminalTranscriptLineCountKey = "settings.ai.terminalTranscriptLineCount"
    static let passwordSaveConsentAcknowledgedKey = "settings.credentials.passwordSaveConsentAcknowledged"
    static let connectionInfoPasswordCopyMuteUntilKey = "settings.credentials.connectionInfoPasswordCopyMuteUntil"
    static let connectionInfoPasswordCopyMuteForeverKey = "settings.credentials.connectionInfoPasswordCopyMuteForever"
    static let serverMetricsActiveRefreshSecondsKey = "settings.metrics.activeRefreshSeconds"
    static let serverMetricsInactiveRefreshSecondsKey = "settings.metrics.inactiveRefreshSeconds"
    static let serverMetricsMaxConcurrentFetchesKey = "settings.metrics.maxConcurrentFetches"

    static let defaultServerMetricsActiveRefreshSeconds = 4
    static let defaultServerMetricsInactiveRefreshSeconds = 10
    static let defaultServerMetricsMaxConcurrentFetches = 2
    static let defaultAIEnabled = true
    static let defaultAIActiveProvider = AIProviderOption.openAI.rawValue
    static let defaultAIAPIFormat = AIProviderOption.openAI.defaultAPIFormat.rawValue
    static let defaultAIBaseURL = AIProviderOption.openAI.defaultBaseURL
    static let defaultAIModel = "gpt-5.4"
    static let defaultAISmartAssistEnabled = true
    static let defaultAIIncludeWorkingDirectory = true
    static let defaultAIIncludeTranscript = true
    static let defaultAITerminalTranscriptLineCount = 120

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

    static func clampedAITerminalTranscriptLineCount(_ value: Int) -> Int {
        min(max(value, 20), 400)
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
