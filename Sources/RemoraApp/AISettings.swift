import Foundation

struct AIModelPreset: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
}

enum AIAPIFormatOption: String, CaseIterable, Identifiable, Sendable {
    case openAIResponses = "openai_responses"
    case openAIChatCompletions = "openai_chat_completions"
    case anthropicMessages = "anthropic_messages"
    case geminiGenerateContent = "gemini_generate_content"
    case compatibleCustom = "compatible_custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAIResponses:
            return "OpenAI Responses"
        case .openAIChatCompletions:
            return "OpenAI Chat Completions"
        case .anthropicMessages:
            return "Anthropic Messages"
        case .geminiGenerateContent:
            return "Gemini GenerateContent"
        case .compatibleCustom:
            return "Compatible Custom"
        }
    }

    static func resolved(from rawValue: String) -> AIAPIFormatOption {
        AIAPIFormatOption(rawValue: rawValue) ?? .openAIResponses
    }
}

enum AIProviderOption: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case qwen = "qwen"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        case .qwen:
            return "Qwen"
        case .custom:
            return "Custom"
        }
    }

    var suggestedModels: [AIModelPreset] {
        switch self {
        case .openAI:
            return [
                AIModelPreset(id: "gpt-4.1", displayName: "GPT-4.1"),
                AIModelPreset(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
                AIModelPreset(id: "gpt-4o-mini", displayName: "GPT-4o Mini")
            ]
        case .anthropic:
            return [
                AIModelPreset(id: "claude-3-7-sonnet-latest", displayName: "Claude 3.7 Sonnet"),
                AIModelPreset(id: "claude-3-5-haiku-latest", displayName: "Claude 3.5 Haiku")
            ]
        case .gemini:
            return [
                AIModelPreset(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash"),
                AIModelPreset(id: "gemini-2.0-flash-lite", displayName: "Gemini 2.0 Flash Lite")
            ]
        case .qwen:
            return [
                AIModelPreset(id: "qwen-max", displayName: "Qwen Max"),
                AIModelPreset(id: "qwen-plus", displayName: "Qwen Plus"),
                AIModelPreset(id: "qwen-turbo", displayName: "Qwen Turbo")
            ]
        case .custom:
            return []
        }
    }

    var defaultModel: AIModelPreset {
        if let first = suggestedModels.first {
            return first
        }
        return AIModelPreset(id: "custom-model", displayName: "Custom Model")
    }

    var defaultAPIFormat: AIAPIFormatOption {
        switch self {
        case .openAI:
            return .openAIResponses
        case .anthropic:
            return .anthropicMessages
        case .gemini:
            return .geminiGenerateContent
        case .qwen:
            return .openAIChatCompletions
        case .custom:
            return .compatibleCustom
        }
    }

    func defaultEndpoint(for format: AIAPIFormatOption? = nil) -> String {
        let resolvedFormat = format ?? defaultAPIFormat
        switch resolvedFormat {
        case .openAIResponses, .openAIChatCompletions:
            if self == .qwen {
                return "https://dashscope.aliyuncs.com/compatible-mode/v1"
            }
            return "https://api.openai.com/v1"
        case .anthropicMessages:
            return "https://api.anthropic.com"
        case .geminiGenerateContent:
            return "https://generativelanguage.googleapis.com"
        case .compatibleCustom:
            return self == .custom ? "" : defaultEndpoint(for: defaultAPIFormat)
        }
    }

    static func resolved(from rawValue: String) -> AIProviderOption {
        AIProviderOption(rawValue: rawValue) ?? .openAI
    }
}
