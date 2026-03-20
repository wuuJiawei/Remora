import Foundation

enum TerminalAICommandRisk: String, Codable, Equatable, Sendable {
    case safe
    case review
    case danger
}

struct TerminalAICommandSuggestion: Codable, Equatable, Sendable {
    var command: String
    var purpose: String
    var risk: TerminalAICommandRisk
}

struct TerminalAIResponse: Codable, Equatable, Sendable {
    var summary: String
    var commands: [TerminalAICommandSuggestion]
    var warnings: [String]
}

struct TerminalAIRequestContext: Equatable, Sendable {
    var userPrompt: String
    var sessionMode: String?
    var hostLabel: String?
    var workingDirectory: String?
    var transcript: String?
    var preferredResponseLanguage: String?
    var conversationContext: String?

    init(
        userPrompt: String,
        sessionMode: String? = nil,
        hostLabel: String? = nil,
        workingDirectory: String? = nil,
        transcript: String? = nil,
        preferredResponseLanguage: String? = nil,
        conversationContext: String? = nil
    ) {
        self.userPrompt = userPrompt
        self.sessionMode = sessionMode
        self.hostLabel = hostLabel
        self.workingDirectory = workingDirectory
        self.transcript = transcript
        self.preferredResponseLanguage = preferredResponseLanguage
        self.conversationContext = conversationContext
    }
}

struct TerminalAIServiceConfiguration: Equatable, Sendable {
    var baseURL: String
    var apiFormat: AIAPIFormatOption
    var model: String
    var apiKey: String
}

enum TerminalAIServiceError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpError(Int)
    case missingContent
    case undecodablePayload

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The AI base URL is invalid."
        case .invalidResponse:
            return "The AI provider returned an invalid response."
        case .httpError(let statusCode):
            return "The AI provider request failed with HTTP \(statusCode)."
        case .missingContent:
            return "The AI provider response did not include assistant content."
        case .undecodablePayload:
            return "The AI provider response could not be decoded into Remora's assistant format."
        }
    }
}
