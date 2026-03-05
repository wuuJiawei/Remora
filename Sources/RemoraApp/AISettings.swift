import Foundation

struct AIModelPreset: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
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

    static func resolved(from rawValue: String) -> AIProviderOption {
        AIProviderOption(rawValue: rawValue) ?? .openAI
    }
}
