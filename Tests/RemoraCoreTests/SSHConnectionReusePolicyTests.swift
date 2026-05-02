import Testing
@testable import RemoraCore

struct SSHConnectionReusePolicyTests {
    @Test
    func passwordAuthWithoutStoredPasswordPrefersConnectionReuse() {
        #expect(
            SSHConnectionReusePolicy.shouldUseConnectionReuse(
                authMethod: .password,
                hasStoredPassword: false
            )
        )
    }

    @Test
    func passwordAuthWithStoredPasswordDoesNotRequireConnectionReuse() {
        #expect(
            !SSHConnectionReusePolicy.shouldUseConnectionReuse(
                authMethod: .password,
                hasStoredPassword: true
            )
        )
    }

    @Test
    func nonPasswordAuthKeepsConnectionReuseEnabled() {
        #expect(
            SSHConnectionReusePolicy.shouldUseConnectionReuse(
                authMethod: .agent,
                hasStoredPassword: false
            )
        )
        #expect(
            SSHConnectionReusePolicy.shouldUseConnectionReuse(
                authMethod: .privateKey,
                hasStoredPassword: false
            )
        )
    }
}
