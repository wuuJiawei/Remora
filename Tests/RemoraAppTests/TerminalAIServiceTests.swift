import Foundation
import Testing
@testable import RemoraApp

@Suite(.serialized)
struct TerminalAIServiceTests {
    @Test
    func openAICompatibleRequestsUseChatCompletionsShape() async throws {
        let harness = HTTPTestHarness(responseStatusCode: 200) { _ in
            openAIResponseJSON(
                content: "{\"summary\":\"Listed likely next steps.\",\"commands\":[{\"command\":\"ls -lah\",\"purpose\":\"Inspect the current directory.\",\"risk\":\"safe\"}],\"warnings\":[]}"
            )
        }

        let service = TerminalAIService(session: harness.session) { request in
            Task {
                await harness.recordPreparedRequest(request)
            }
        }
        let configuration = TerminalAIServiceConfiguration(
            baseURL: "https://example.com/v1",
            apiFormat: .openAICompatible,
            model: "gpt-4.1-mini",
            apiKey: "sk-openai"
        )

        let response = try await service.respond(
            to: TerminalAIRequestContext(
                userPrompt: "Show me the largest files here.",
                sessionMode: "SSH",
                hostLabel: "prod-box",
                workingDirectory: "/var/log",
                transcript: "permission denied"
            ),
            configuration: configuration
        )

        let request = try #require(await harness.lastRequest)
        let body = try #require(request.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])

        #expect(request.url?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openai")
        #expect(bodyJSON["model"] as? String == "gpt-4.1-mini")
        #expect(messages.count == 2)
        #expect(response.summary == "Listed likely next steps.")
        #expect(response.commands.count == 1)
        #expect(response.commands.first?.command == "ls -lah")
    }

    @Test
    func claudeCompatibleRequestsUseMessagesShape() async throws {
        let harness = HTTPTestHarness(responseStatusCode: 200) { _ in
            claudeResponseJSON(
                text: "{\"summary\":\"Explained the failure.\",\"commands\":[{\"command\":\"pwd\",\"purpose\":\"Confirm the current directory.\",\"risk\":\"safe\"}],\"warnings\":[\"Check permissions before retrying.\"]}"
            )
        }

        let service = TerminalAIService(session: harness.session) { request in
            Task {
                await harness.recordPreparedRequest(request)
            }
        }
        let configuration = TerminalAIServiceConfiguration(
            baseURL: "https://claude.example.com",
            apiFormat: .claudeCompatible,
            model: "claude-sonnet",
            apiKey: "sk-claude"
        )

        let response = try await service.respond(
            to: TerminalAIRequestContext(userPrompt: "Why did this fail?"),
            configuration: configuration
        )

        let request = try #require(await harness.lastRequest)
        let body = try #require(request.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])

        #expect(request.url?.absoluteString == "https://claude.example.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-claude")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(bodyJSON["model"] as? String == "claude-sonnet")
        #expect(messages.count == 1)
        #expect(response.warnings == ["Check permissions before retrying."])
    }

    @Test
    func responseDecoderAcceptsMarkdownWrappedJSONPayload() async throws {
        let harness = HTTPTestHarness(responseStatusCode: 200) { _ in
            openAIResponseJSON(
                content: "```json\n{\"summary\":\"Wrapped payload.\",\"commands\":[],\"warnings\":[]}\n```"
            )
        }

        let service = TerminalAIService(session: harness.session)
        let response = try await service.respond(
            to: TerminalAIRequestContext(userPrompt: "Explain this output."),
            configuration: TerminalAIServiceConfiguration(
                baseURL: "https://example.com/v1",
                apiFormat: .openAICompatible,
                model: "gpt-4.1-mini",
                apiKey: "sk-openai"
            )
        )

        #expect(response.summary == "Wrapped payload.")
        #expect(response.commands.isEmpty)
    }
}

private actor HTTPTestHarness {
    let session: URLSession
    private let recorder: RequestRecorder

    init(responseStatusCode: Int, responder: @escaping @Sendable (URLRequest) -> String) {
        recorder = RequestRecorder()

        HTTPTestURLProtocol.handler = { request in
            let data = Data(responder(request).utf8)
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: responseStatusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPTestURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func recordPreparedRequest(_ request: URLRequest) async {
        await recorder.record(request)
    }

    var lastRequest: URLRequest? {
        get async {
            await recorder.lastRequest
        }
    }
}

private actor RequestRecorder {
    private(set) var lastRequest: URLRequest?

    func record(_ request: URLRequest) {
        lastRequest = request
    }
}

private final class HTTPTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func openAIResponseJSON(content: String) -> String {
    jsonString(
        [
            "choices": [
                [
                    "message": [
                        "content": content,
                    ],
                ],
            ],
        ]
    )
}

private func claudeResponseJSON(text: String) -> String {
    jsonString(
        [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ],
            ],
        ]
    )
}

private func jsonString(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
