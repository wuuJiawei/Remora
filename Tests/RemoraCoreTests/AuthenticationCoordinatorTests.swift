import Testing
@testable import RemoraCore

@Suite("Authentication coordinator")
struct AuthenticationCoordinatorTests {
    @Test("Keyboard-interactive requires one response per prompt")
    func requiresExactResponseCount() async throws {
        let coordinator = AuthenticationCoordinator(challengeTimeout: .seconds(5))
        var challenges = coordinator.challenges().makeAsyncIterator()
        let responseTask = Task.detached {
            coordinator.bridge.requestResponses(
                name: "JumpServer MFA",
                instruction: "Complete all fields",
                prompts: [
                    KeyboardInteractivePrompt(text: "Username:", echo: true),
                    KeyboardInteractivePrompt(text: "Code:", echo: false),
                ]
            )
        }
        let challenge = try #require(await challenges.next())

        #expect(!coordinator.respond(to: challenge.id, responses: ["operator"]))
        #expect(coordinator.respond(to: challenge.id, responses: ["operator", "123456"]))
        let responses = await responseTask.value
        #expect(responses == ["operator", "123456"])
    }

    @Test("Automatic response provider must return the exact prompt count")
    func automaticResponseCountIsValidated() async {
        let coordinator = AuthenticationCoordinator(
            challengeTimeout: .milliseconds(20),
            automaticResponseProvider: { _ in ["too-few"] }
        )

        let responses = await Task.detached {
            coordinator.bridge.requestResponses(
                name: "MFA",
                instruction: "",
                prompts: [
                    KeyboardInteractivePrompt(text: "Password:", echo: false),
                    KeyboardInteractivePrompt(text: "Code:", echo: false),
                ]
            )
        }.value

        #expect(responses == nil)
    }
}
