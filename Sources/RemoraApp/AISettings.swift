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

    static let `default` = AISettingsValue(
        isEnabled: AppSettings.defaultAIEnabled,
        provider: .openAI,
        apiFormat: .openAICompatible,
        baseURL: AppSettings.defaultAIBaseURL,
        model: AppSettings.defaultAIModel,
        smartAssistEnabled: AppSettings.defaultAISmartAssistEnabled,
        includeWorkingDirectory: AppSettings.defaultAIIncludeWorkingDirectory,
        includeTranscript: AppSettings.defaultAIIncludeTranscript,
        terminalTranscriptLineCount: AppSettings.defaultAITerminalTranscriptLineCount
    )
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
                AIModelPreset(id: "gpt-4.1", displayName: "GPT-4.1"),
                AIModelPreset(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
            ]
        case .anthropic:
            return [
                AIModelPreset(id: "claude-3-7-sonnet-latest", displayName: "Claude 3.7 Sonnet"),
                AIModelPreset(id: "claude-3-5-haiku-latest", displayName: "Claude 3.5 Haiku"),
            ]
        case .openRouter:
            return [
                AIModelPreset(id: "anthropic/claude-3.7-sonnet", displayName: "Claude 3.7 Sonnet"),
                AIModelPreset(id: "openai/gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
            ]
        case .deepSeek:
            return [
                AIModelPreset(id: "deepseek-chat", displayName: "DeepSeek Chat"),
                AIModelPreset(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner"),
            ]
        case .qwen:
            return [
                AIModelPreset(id: "qwen-max", displayName: "Qwen Max"),
                AIModelPreset(id: "qwen-plus", displayName: "Qwen Plus"),
            ]
        case .ollama, .custom:
            return []
        }
    }

    static func resolved(from rawValue: String) -> AIProviderOption {
        AIProviderOption(rawValue: rawValue) ?? .openAI
    }
}
