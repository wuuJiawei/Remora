import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

@Suite("Terminal runtime keyboard-interactive state", .serialized)
@MainActor
struct TerminalRuntimeKeyboardInteractiveTests {
    @Test("Multiple prompts preserve the complete challenge")
    func multiplePromptsPreserveChallenge() {
        let runtime = makeRuntime()
        let challenge = KeyboardInteractiveChallenge(
            name: "JumpServer MFA",
            instruction: "Complete all fields",
            prompts: [
                KeyboardInteractivePrompt(text: "Username:", echo: true),
                KeyboardInteractivePrompt(text: "Verification code:", echo: false),
            ],
            deadline: Date().addingTimeInterval(60)
        )

        runtime.handleNativeKeyboardInteractiveChallenge(challenge)

        #expect(runtime.keyboardInteractiveChallenge == challenge)
        #expect(runtime.passwordPromptMessage == nil)
        #expect(runtime.otpPromptMessage == nil)
        #expect(runtime.connectionState == "Waiting (authentication)")
        #expect(!runtime.respondToKeyboardInteractivePrompt(responses: ["only-one-response"]))
        #expect(runtime.keyboardInteractiveChallenge == challenge)
    }

    @Test("Single OTP prompt continues to use the compact alert")
    func singleOTPPromptUsesCompactAlert() {
        let runtime = makeRuntime()
        let challenge = KeyboardInteractiveChallenge(
            name: "",
            instruction: "",
            prompts: [KeyboardInteractivePrompt(text: "MFA code:", echo: false)],
            deadline: Date().addingTimeInterval(60)
        )

        runtime.handleNativeKeyboardInteractiveChallenge(challenge)

        #expect(runtime.keyboardInteractiveChallenge == nil)
        #expect(runtime.otpPromptMessage != nil)
        #expect(runtime.connectionState == "Waiting (otp)")
    }

    @Test("Cancelling a multi-prompt challenge clears UI state")
    func cancellingChallengeClearsState() {
        let runtime = makeRuntime()
        runtime.handleNativeKeyboardInteractiveChallenge(
            KeyboardInteractiveChallenge(
                name: "MFA",
                instruction: "",
                prompts: [
                    KeyboardInteractivePrompt(text: "Password:", echo: false),
                    KeyboardInteractivePrompt(text: "Code:", echo: false),
                ],
                deadline: Date().addingTimeInterval(60)
            )
        )

        runtime.dismissKeyboardInteractivePrompt()

        #expect(runtime.keyboardInteractiveChallenge == nil)
    }

    private func makeRuntime() -> TerminalRuntime {
        let manager = makeMockSessionManager()
        return TerminalRuntime(
            localSessionManager: manager,
            sshSessionManager: manager
        )
    }
}
