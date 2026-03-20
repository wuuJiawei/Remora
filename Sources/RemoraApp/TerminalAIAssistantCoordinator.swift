import Combine
import Foundation

protocol TerminalAIResponding: Sendable {
    func respond(
        to context: TerminalAIRequestContext,
        configuration: TerminalAIServiceConfiguration
    ) async throws -> TerminalAIResponse
}

extension TerminalAIService: TerminalAIResponding {}

struct TerminalAIRuntimeSnapshot: Equatable, Sendable {
    var sessionMode: String?
    var hostLabel: String?
    var workingDirectory: String?
    var transcript: String?

    static let empty = TerminalAIRuntimeSnapshot(
        sessionMode: nil,
        hostLabel: nil,
        workingDirectory: nil,
        transcript: nil
    )
}

enum TerminalAIAssistantCoordinatorError: Error, Equatable {
    case sessionNotBound
    case aiDisabled
    case emptyPrompt
    case missingAPIKey
}

struct TerminalAIAssistantMessage: Identifiable, Equatable {
    let id: UUID
    let prompt: String?
    let response: TerminalAIResponse?
    let streamedText: String?
    let isThinking: Bool
    let isStreaming: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        prompt: String? = nil,
        response: TerminalAIResponse? = nil,
        streamedText: String? = nil,
        isThinking: Bool = false,
        isStreaming: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.prompt = prompt
        self.response = response
        self.streamedText = streamedText
        self.isThinking = isThinking
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }
}

enum TerminalAISmartAssistKind: Equatable {
    case permissionDenied
    case commandNotFound
    case missingPath
}

struct TerminalAISmartAssist: Equatable {
    var kind: TerminalAISmartAssistKind
    var title: String
    var prompt: String
}

@MainActor
final class TerminalAIAssistantCoordinator: ObservableObject {
    @Published private(set) var messages: [TerminalAIAssistantMessage] = []
    @Published private(set) var smartAssist: TerminalAISmartAssist?
    @Published private(set) var isResponding = false

    private let service: any TerminalAIResponding
    private let settingsStore: AISettingsStore
    private let runtimeSnapshot: () -> TerminalAIRuntimeSnapshot
    private let streamingChunkDelayNanoseconds: UInt64
    private var boundSessionID: UUID?
    private var messagesBySession: [UUID: [TerminalAIAssistantMessage]] = [:]

    init(
        service: any TerminalAIResponding = TerminalAIService(),
        settingsStore: AISettingsStore = AISettingsStore(),
        runtimeSnapshot: @escaping () -> TerminalAIRuntimeSnapshot = { .empty },
        streamingChunkDelayNanoseconds: UInt64 = 14_000_000
    ) {
        self.service = service
        self.settingsStore = settingsStore
        self.runtimeSnapshot = runtimeSnapshot
        self.streamingChunkDelayNanoseconds = streamingChunkDelayNanoseconds
    }

    func bind(to sessionID: UUID) {
        boundSessionID = sessionID
        messages = messagesBySession[sessionID, default: []]
        refreshSmartAssist()
    }

    func submit(_ prompt: String) async throws {
        guard let sessionID = boundSessionID else {
            throw TerminalAIAssistantCoordinatorError.sessionNotBound
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw TerminalAIAssistantCoordinatorError.emptyPrompt
        }

        let settings = settingsStore.load()
        guard settings.isEnabled else {
            throw TerminalAIAssistantCoordinatorError.aiDisabled
        }

        guard let apiKey = await settingsStore.apiKey(), !apiKey.isEmpty else {
            throw TerminalAIAssistantCoordinatorError.missingAPIKey
        }

        append(.init(prompt: trimmedPrompt), to: sessionID)
        let assistantMessageID = UUID()
        append(.init(id: assistantMessageID, streamedText: "", isThinking: true), to: sessionID)
        isResponding = true
        defer { isResponding = false }

        let snapshot = runtimeSnapshot()
        let context = TerminalAIRequestContext(
            userPrompt: trimmedPrompt,
            sessionMode: snapshot.sessionMode,
            hostLabel: snapshot.hostLabel,
            workingDirectory: settings.includeWorkingDirectory ? snapshot.workingDirectory : nil,
            transcript: settings.includeTranscript
                ? clippedTranscript(snapshot.transcript, maxLines: settings.terminalTranscriptLineCount)
                : nil
        )

        do {
            let response = try await service.respond(
                to: context,
                configuration: TerminalAIServiceConfiguration(
                    baseURL: settings.baseURL,
                    apiFormat: settings.apiFormat,
                    model: settings.model,
                    apiKey: apiKey
                )
            )

            try await streamSummary(response.summary, messageID: assistantMessageID, sessionID: sessionID)
            replaceMessage(
                id: assistantMessageID,
                in: sessionID,
                with: TerminalAIAssistantMessage(id: assistantMessageID, response: response)
            )
        } catch {
            removeMessage(id: assistantMessageID, from: sessionID)
            throw error
        }

        refreshSmartAssist()
    }

    func refreshSmartAssist() {
        let settings = settingsStore.load()
        guard settings.isEnabled, settings.smartAssistEnabled else {
            smartAssist = nil
            return
        }

        smartAssist = detectSmartAssist(in: runtimeSnapshot().transcript)
    }

    private func append(_ message: TerminalAIAssistantMessage, to sessionID: UUID) {
        var existing = messagesBySession[sessionID, default: []]
        existing.append(message)
        messagesBySession[sessionID] = existing

        if boundSessionID == sessionID {
            messages = existing
        }
    }

    private func replaceMessage(id: UUID, in sessionID: UUID, with message: TerminalAIAssistantMessage) {
        guard var existing = messagesBySession[sessionID],
              let index = existing.firstIndex(where: { $0.id == id }) else {
            return
        }

        existing[index] = message
        messagesBySession[sessionID] = existing

        if boundSessionID == sessionID {
            messages = existing
        }
    }

    private func removeMessage(id: UUID, from sessionID: UUID) {
        guard var existing = messagesBySession[sessionID] else { return }
        existing.removeAll { $0.id == id }
        messagesBySession[sessionID] = existing

        if boundSessionID == sessionID {
            messages = existing
        }
    }

    private func streamSummary(_ summary: String, messageID: UUID, sessionID: UUID) async throws {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            replaceMessage(
                id: messageID,
                in: sessionID,
                with: TerminalAIAssistantMessage(id: messageID, streamedText: "", isThinking: false, isStreaming: false)
            )
            return
        }

        var streamed = ""
        let chunks = summaryChunks(for: trimmedSummary)
        for (index, chunk) in chunks.enumerated() {
            if streamingChunkDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: streamingChunkDelayNanoseconds)
            }
            streamed.append(chunk)
            replaceMessage(
                id: messageID,
                in: sessionID,
                with: TerminalAIAssistantMessage(
                    id: messageID,
                    streamedText: streamed,
                    isThinking: false,
                    isStreaming: index < chunks.count - 1
                )
            )
        }
    }

    private func summaryChunks(for text: String) -> [String] {
        let characters = Array(text)
        let chunkSize = max(3, min(8, characters.count / 12 == 0 ? 4 : characters.count / 12))
        var chunks: [String] = []
        var index = 0
        while index < characters.count {
            let end = min(index + chunkSize, characters.count)
            chunks.append(String(characters[index..<end]))
            index = end
        }
        return chunks
    }

    private func clippedTranscript(_ transcript: String?, maxLines: Int) -> String? {
        guard let transcript else { return nil }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed.components(separatedBy: .newlines)
        let clipped = lines.suffix(AppSettings.clampedAITerminalTranscriptLineCount(maxLines))
        return clipped.joined(separator: "\n")
    }

    private func detectSmartAssist(in transcript: String?) -> TerminalAISmartAssist? {
        guard let transcript else { return nil }
        let normalized = transcript.lowercased()

        if normalized.contains("permission denied") || normalized.contains("operation not permitted") {
            return TerminalAISmartAssist(
                kind: .permissionDenied,
                title: "Permission denied",
                prompt: "Explain why this terminal command hit permission denied and suggest the safest next command."
            )
        }

        if normalized.contains("command not found") {
            return TerminalAISmartAssist(
                kind: .commandNotFound,
                title: "Command not found",
                prompt: "Explain why this terminal command was not found and suggest the safest next command."
            )
        }

        if normalized.contains("no such file") || normalized.contains("no such file or directory") {
            return TerminalAISmartAssist(
                kind: .missingPath,
                title: "Missing file or path",
                prompt: "Explain why this terminal command could not find the file or directory and suggest the safest next command."
            )
        }

        return nil
    }
}
