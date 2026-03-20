import Foundation

struct AIModelPreset: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
}

struct AISettingsValue: Equatable, Sendable {
    var isEnabled: Bool
    var provider: AIProviderOption
    var apiFormat: AIAPIFormatOption
    var baseURL: String
    var model: String
    var smartAssistEnabled: Bool
    var includeWorkingDirectory: Bool
    var includeTranscript: Bool
    var terminalTranscriptLineCount: Int
    var language: AILanguageOption
    var requireRunConfirmation: Bool

    static let `default` = AISettingsValue(
        isEnabled: AppSettings.defaultAIEnabled,
        provider: .openAI,
        apiFormat: .openAICompatible,
        baseURL: AppSettings.defaultAIBaseURL,
        model: AppSettings.defaultAIModel,
        smartAssistEnabled: AppSettings.defaultAISmartAssistEnabled,
        includeWorkingDirectory: AppSettings.defaultAIIncludeWorkingDirectory,
        includeTranscript: AppSettings.defaultAIIncludeTranscript,
        terminalTranscriptLineCount: AppSettings.defaultAITerminalTranscriptLineCount,
        language: .system,
        requireRunConfirmation: AppSettings.defaultAIRequireRunConfirmation
    )
}

enum AILanguageOption: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case english = "english"
    case simplifiedChinese = "simplified_chinese"

    var id: String { rawValue }

    var promptLabel: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.contains("zh") ? "Simplified Chinese" : "English"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "Simplified Chinese"
        }
    }

    static func resolved(from rawValue: String) -> AILanguageOption {
        AILanguageOption(rawValue: rawValue) ?? .system
    }
}

enum AIAPIFormatOption: String, CaseIterable, Identifiable, Sendable {
    case openAICompatible = "openai_compatible"
    case claudeCompatible = "claude_compatible"

    var id: String { rawValue }

    static func resolved(from rawValue: String) -> AIAPIFormatOption {
        AIAPIFormatOption(rawValue: rawValue) ?? .openAICompatible
    }
}

enum AIProviderOption: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case openRouter = "openrouter"
    case deepSeek = "deepseek"
    case qwen = "qwen"
    case ollama = "ollama"
    case custom = "custom"

    var id: String { rawValue }

    var defaultAPIFormat: AIAPIFormatOption {
        switch self {
        case .anthropic:
            return .claudeCompatible
        default:
            return .openAICompatible
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .deepSeek:
            return "https://api.deepseek.com/v1"
        case .qwen:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .ollama:
            return "http://localhost:11434/v1"
        case .custom:
            return ""
        }
    }

    var suggestedModels: [AIModelPreset] {
        switch self {
        case .openAI:
            return [
                AIModelPreset(id: "gpt-5.4", displayName: "GPT-5.4"),
                AIModelPreset(id: "gpt-5.2", displayName: "GPT-5.2"),
                AIModelPreset(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
                AIModelPreset(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
                AIModelPreset(id: "gpt-5.1-codex", displayName: "GPT-5.1 Codex"),
                AIModelPreset(id: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max"),
                AIModelPreset(id: "gpt-5.1-codex-mini", displayName: "GPT-5.1 Codex Mini"),
                AIModelPreset(id: "gpt-5-codex", displayName: "GPT-5 Codex"),
                AIModelPreset(id: "codex-mini-latest", displayName: "Codex Mini"),
            ]
        case .anthropic:
            return [
                AIModelPreset(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5"),
                AIModelPreset(id: "claude-opus-4-1", displayName: "Claude Opus 4.1"),
                AIModelPreset(id: "claude-sonnet-4", displayName: "Claude Sonnet 4"),
                AIModelPreset(id: "claude-3-7-sonnet-latest", displayName: "Claude 3.7 Sonnet"),
            ]
        case .openRouter:
            return [
                AIModelPreset(id: "openai/gpt-5.4", displayName: "OpenAI GPT-5.4"),
                AIModelPreset(id: "openai/gpt-5.3-codex", displayName: "OpenAI GPT-5.3 Codex"),
                AIModelPreset(id: "anthropic/claude-sonnet-4.5", displayName: "Claude Sonnet 4.5"),
                AIModelPreset(id: "anthropic/claude-opus-4.1", displayName: "Claude Opus 4.1"),
            ]
        case .deepSeek:
            return [
                AIModelPreset(id: "deepseek-chat", displayName: "DeepSeek Chat (V3.2)"),
                AIModelPreset(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner (R1)"),
            ]
        case .qwen:
            return [
                AIModelPreset(id: "qwen3.5-plus", displayName: "Qwen 3.5 Plus"),
                AIModelPreset(id: "qwen-max", displayName: "Qwen Max"),
                AIModelPreset(id: "qwen-plus", displayName: "Qwen Plus"),
                AIModelPreset(id: "qwen-turbo", displayName: "Qwen Turbo"),
            ]
        case .ollama, .custom:
            return []
        }
    }

    static func resolved(from rawValue: String) -> AIProviderOption {
        AIProviderOption(rawValue: rawValue) ?? .openAI
    }
}
