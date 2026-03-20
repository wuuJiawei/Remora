import Foundation

final class TerminalAIService: @unchecked Sendable {
    private let session: URLSession
    private let requestObserver: (@Sendable (URLRequest) -> Void)?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared, requestObserver: (@Sendable (URLRequest) -> Void)? = nil) {
        self.session = session
        self.requestObserver = requestObserver
    }

    func respond(
        to context: TerminalAIRequestContext,
        configuration: TerminalAIServiceConfiguration
    ) async throws -> TerminalAIResponse {
        let request = try buildRequest(context: context, configuration: configuration)
        requestObserver?(request)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TerminalAIServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw TerminalAIServiceError.httpError(httpResponse.statusCode)
        }

        let content: String
        switch configuration.apiFormat {
        case .openAICompatible:
            content = try decodeOpenAIContent(from: data)
        case .claudeCompatible:
            content = try decodeClaudeContent(from: data)
        }

        return try decodeAssistantPayload(from: content)
    }

    private func buildRequest(
        context: TerminalAIRequestContext,
        configuration: TerminalAIServiceConfiguration
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint(for: configuration)) else {
            throw TerminalAIServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = userPrompt(from: context)

        switch configuration.apiFormat {
        case .openAICompatible:
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try encoder.encode(
                OpenAIRequestBody(
                    model: configuration.model,
                    messages: [
                        .init(role: "system", content: systemPrompt),
                        .init(role: "user", content: prompt),
                    ]
                )
            )
        case .claudeCompatible:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try encoder.encode(
                ClaudeRequestBody(
                    model: configuration.model,
                    system: systemPrompt,
                    messages: [
                        .init(role: "user", content: prompt),
                    ]
                )
            )
        }

        return request
    }

    private func endpoint(for configuration: TerminalAIServiceConfiguration) -> String {
        let trimmedBaseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = trimmedBaseURL.hasSuffix("/") ? String(trimmedBaseURL.dropLast()) : trimmedBaseURL

        switch configuration.apiFormat {
        case .openAICompatible:
            return normalizedBaseURL.hasSuffix("/chat/completions")
                ? normalizedBaseURL
                : normalizedBaseURL + "/chat/completions"
        case .claudeCompatible:
            return normalizedBaseURL.hasSuffix("/v1/messages")
                ? normalizedBaseURL
                : normalizedBaseURL + "/v1/messages"
        }
    }

    private func userPrompt(from context: TerminalAIRequestContext) -> String {
        var sections: [String] = []

        if let sessionMode = normalized(context.sessionMode) {
            sections.append("Session Mode: \(sessionMode)")
        }
        if let hostLabel = normalized(context.hostLabel) {
            sections.append("Host: \(hostLabel)")
        }
        if let workingDirectory = normalized(context.workingDirectory) {
            sections.append("Working Directory: \(workingDirectory)")
        }
        if let transcript = normalized(context.transcript) {
            sections.append("Recent Output:\n\(transcript)")
        }
        if let conversationContext = normalized(context.conversationContext) {
            sections.append("Conversation Context:\n\(conversationContext)")
        }
        if let preferredResponseLanguage = normalized(context.preferredResponseLanguage) {
            sections.append("Preferred Response Language: \(preferredResponseLanguage)")
        }

        sections.append("User Request: \(context.userPrompt)")
        return sections.joined(separator: "\n\n")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodeOpenAIContent(from data: Data) throws -> String {
        let payload = try decoder.decode(OpenAIResponseBody.self, from: data)
        guard let content = payload.choices.first?.message.content else {
            throw TerminalAIServiceError.missingContent
        }
        return content
    }

    private func decodeClaudeContent(from data: Data) throws -> String {
        let payload = try decoder.decode(ClaudeResponseBody.self, from: data)
        guard let text = payload.content.first(where: { $0.type == "text" })?.text else {
            throw TerminalAIServiceError.missingContent
        }
        return text
    }

    private func decodeAssistantPayload(from rawContent: String) throws -> TerminalAIResponse {
        let cleaned = cleanedJSONContent(from: rawContent)
        guard let data = cleaned.data(using: .utf8) else {
            throw TerminalAIServiceError.undecodablePayload
        }
        do {
            return try decoder.decode(TerminalAIResponse.self, from: data)
        } catch {
            throw TerminalAIServiceError.undecodablePayload
        }
    }

    private func cleanedJSONContent(from rawContent: String) -> String {
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var systemPrompt: String {
        """
        You are Remora's terminal assistant. Respond with JSON only using this schema: {\"summary\": string, \"commands\": [{\"command\": string, \"purpose\": string, \"risk\": \"safe\"|\"review\"|\"danger\"}], \"warnings\": [string]}. Keep the summary concise. Suggest only commands relevant to the provided terminal context.
        """
    }
}

private struct OpenAIRequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct ClaudeRequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let max_tokens: Int = 1200
    let system: String
    let messages: [Message]
}

private struct OpenAIResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct ClaudeResponseBody: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    let content: [ContentBlock]
}
