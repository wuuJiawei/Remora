import Testing
import Foundation
@testable import RemoraCore

struct SystemSSHClientTests {
    @Test
    func buildsArgumentsForPrivateKeyAuth() {
        let host = Host(
            name: "prod",
            address: "10.0.0.2",
            port: 2222,
            username: "deploy",
            auth: HostAuth(method: .privateKey, keyReference: "/Users/demo/.ssh/id_ed25519"),
            policies: HostPolicies(keepAliveSeconds: 30, connectTimeoutSeconds: 8, terminalProfileID: "default")
        )

        let args = ProcessSSHShellSession.makeSSHArguments(for: host)

        #expect(args.contains("-tt"))
        #expect(args.contains("-p"))
        #expect(args.contains("2222"))
        #expect(args.contains("ConnectTimeout=8"))
        #expect(args.contains("ServerAliveInterval=30"))
        #expect(args.contains("ServerAliveCountMax=3"))
        #expect(args.contains("StrictHostKeyChecking=ask"))
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains(where: { $0.hasPrefix("ControlPath=/tmp/") }))
        #expect(args.contains("-i"))
        #expect(args.contains("/Users/demo/.ssh/id_ed25519"))
        #expect(args.contains("deploy@10.0.0.2"))
    }

    @Test
    func buildsArgumentsForAgentAuth() {
        let host = Host(
            name: "staging",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent),
            policies: HostPolicies(keepAliveSeconds: 3, connectTimeoutSeconds: 0, terminalProfileID: "default")
        )

        let args = ProcessSSHShellSession.makeSSHArguments(for: host)

        #expect(args.contains("ConnectTimeout=1"))
        #expect(args.contains("ServerAliveInterval=5"))
        #expect(args.contains("PreferredAuthentications=publickey"))
    }

    @Test
    func buildsArgumentsForPasswordWithMultiPromptSupport() {
        let host = Host(
            name: "prod-password",
            address: "example.com",
            username: "root",
            auth: HostAuth(method: .password, passwordReference: "pw-ref")
        )

        let args = ProcessSSHShellSession.makeSSHArguments(for: host)

        #expect(args.contains("PreferredAuthentications=keyboard-interactive,password"))
        #expect(args.contains("NumberOfPasswordPrompts=3"))
        #expect(args.contains("PubkeyAuthentication=no"))
        #expect(args.contains("GSSAPIAuthentication=no"))
        #expect(args.contains("KbdInteractiveAuthentication=yes"))
    }

    @Test
    func prefersScriptWrapperWhenAvailable() {
        let host = Host(
            name: "staging",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )

        let launch = ProcessSSHShellSession.makeStandardLaunchConfiguration(for: host)

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            #expect(launch.executablePath == "/usr/bin/script")
            #expect(launch.arguments.starts(with: ["-q", "/dev/null", "/usr/bin/ssh"]))
        } else {
            #expect(launch.executablePath == "/usr/bin/ssh")
        }
    }

    @Test
    func standardLaunchConfigurationProvidesTerminalType() {
        let host = Host(
            name: "ops",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )

        let launch = ProcessSSHShellSession.makeStandardLaunchConfiguration(for: host)
        let expectedTerm = "xterm-256color"

        #expect(launch.environment["TERM"] == expectedTerm)
    }

    @Test
    func standardLaunchConfigurationDoesNotRewriteRemoteShellStartup() {
        let host = Host(
            name: "ops",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )

        let launch = ProcessSSHShellSession.makeStandardLaunchConfiguration(for: host)
        let joinedArguments = launch.arguments.joined(separator: " ")

        #expect(joinedArguments.contains("REMORA_SHELL_INTEGRATION") == false)
        #expect(joinedArguments.contains("PROMPT_COMMAND") == false)
        #expect(joinedArguments.contains("add-zsh-hook") == false)
        #expect(launch.arguments.last == "ubuntu@example.com")
    }

    @Test
    func remoteShellIntegrationInstallCommandConfiguresBashZshAndFishHooks() {
        let command = OpenSSHRemoteShellIntegrationInstaller.installCommand

        #expect(command.unicodeScalars.contains("\0") == false)
        #expect(command.contains("shell-integration.bash"))
        #expect(command.contains("shell-integration.zsh"))
        #expect(command.contains("remora.fish"))
        #expect(command.contains("# >>> Remora shell integration >>>"))
        #expect(command.contains("\\033]7;file://"))
    }

    @Test
    func buildsPasswordLaunchConfigurationWithExplicitHelperTransport() {
        let host = Host(
            name: "prod",
            address: "example.com",
            port: 22,
            username: "root",
            auth: HostAuth(method: .password, passwordReference: "pw-ref")
        )

        let launch = ProcessSSHShellSession.makePasswordLaunchConfiguration(
            for: host,
            password: "top-secret",
            sshpassPath: "/opt/homebrew/bin/sshpass",
            askPassScriptPath: nil
        )

        #expect(launch?.executablePath == "/opt/homebrew/bin/sshpass")
        #expect(launch?.arguments.starts(with: ["-e"]) == true)
        #expect(launch?.environment["SSHPASS"] == "top-secret")
    }

    @Test
    func passwordShellLaunchPlanFallsBackToPTYAutofillWhenSSHPassIsUnavailable() {
        let host = Host(
            name: "prod",
            address: "example.com",
            port: 22,
            username: "root",
            auth: HostAuth(method: .password, passwordReference: "pw-ref")
        )

        let plan = ProcessSSHShellSession.makeShellLaunchPlan(
            for: host,
            storedPassword: "top-secret",
            sshpassPath: nil,
            askPassScriptPath: nil
        )

        #expect(plan.interactivePasswordAutofill == "top-secret")
        #expect(plan.configuration.environment["SSH_ASKPASS"] == nil)
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            #expect(plan.configuration.executablePath == "/usr/bin/script")
        } else {
            #expect(plan.configuration.executablePath == "/usr/bin/ssh")
        }
    }

    @Test
    func runningSessionReportsUpdatedPTYSizeAfterResize() async throws {
        let host = Host(
            name: "pty-test",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )
        let output = OutputCollector()
        let session = ProcessSSHShellSession(
            host: host,
            pty: .init(columns: 80, rows: 24),
            launchConfigurationOverride: ProcessSSHShellSession.LaunchConfiguration(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "printf 'READY\\r\\n'; while IFS= read -r line; do if [ \"$line\" = size ]; then stty size; fi; done"
                ],
                environment: ["TERM": "xterm-256color"]
            )
        )
        session.onOutput = { (data: Data) in
            Task {
                await output.append(String(decoding: data, as: UTF8.self))
            }
        }

        try await session.start()
        #expect(await waitUntil(timeout: 1) { await output.joined.contains("READY") })

        try await session.write(Data("size\n".utf8))
        #expect(
            await waitUntil(timeout: 1) { await output.joined.contains("24 80") },
            "Session should expose the initial PTY size to the child process."
        )

        try await session.resize(PTYSize(columns: 101, rows: 37))
        try await session.write(Data("size\n".utf8))
        #expect(
            await waitUntil(timeout: 1) { await output.joined.contains("37 101") },
            "Resizing the session should update the child PTY, otherwise shells redraw against stale dimensions."
        )

        await session.stop()
    }

    @Test
    func runningSessionAutofillsStoredPasswordAfterHostKeyConfirmation() async throws {
        let host = Host(
            name: "password-test",
            address: "example.com",
            username: "root",
            auth: HostAuth(method: .password, passwordReference: "pw-ref")
        )
        let output = OutputCollector()
        let session = ProcessSSHShellSession(
            host: host,
            pty: .init(columns: 80, rows: 24),
            launchConfigurationOverride: ProcessSSHShellSession.LaunchConfiguration(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "printf 'Are you sure you want to continue connecting (yes/no/[fingerprint])? '; IFS= read -r trust; printf '\\r\\nroot@example.com password:'; IFS= read -r pw; if [ \"$trust\" = yes ] && [ \"$pw\" = top-secret ]; then printf '\\r\\nREADY\\r\\n'; else printf '\\r\\nBAD trust=%s pw=%s\\r\\n' \"$trust\" \"$pw\"; fi"
                ],
                environment: ["TERM": "xterm-256color"]
            ),
            interactivePasswordAutofillOverride: "top-secret"
        )
        session.onOutput = { (data: Data) in
            Task {
                await output.append(String(decoding: data, as: UTF8.self))
            }
        }

        try await session.start()
        #expect(
            await waitUntil(timeout: 1) {
                await output.joined.contains("continue connecting")
            }
        )

        try await session.write(Data("yes\n".utf8))
        #expect(
            await waitUntil(timeout: 1) { await output.joined.contains("READY") },
            "Interactive shells should preserve host-key confirmation while still sending the saved password once ssh prompts for it."
        )

        await session.stop()
    }

    @Test
    func runningSessionDoesNotAutofillPasswordAfterAuthWindowExpires() async throws {
        let host = Host(
            name: "password-timeout",
            address: "example.com",
            username: "root",
            auth: HostAuth(method: .password, passwordReference: "pw-ref")
        )
        let output = OutputCollector()
        let session = ProcessSSHShellSession(
            host: host,
            pty: .init(columns: 80, rows: 24),
            launchConfigurationOverride: ProcessSSHShellSession.LaunchConfiguration(
                executablePath: "/bin/bash",
                arguments: [
                    "-lc",
                    "sleep 1; printf 'password:'; if IFS= read -r -t 1 pw; then if [ \"$pw\" = top-secret ]; then printf '\\r\\nLEAKED\\r\\n'; else printf '\\r\\nUNEXPECTED\\r\\n'; fi; else printf '\\r\\nSAFE\\r\\n'; fi"
                ],
                environment: ["TERM": "xterm-256color"]
            ),
            interactivePasswordAutofillWindow: 0.25,
            initialSkipAutoPasswordDelivery: true,
            cachedStoredPasswordOverride: "top-secret"
        )
        session.onOutput = { (data: Data) in
            Task {
                await output.append(String(decoding: data, as: UTF8.self))
            }
        }

        try await session.start()
        #expect(
            await waitUntil(timeout: 3) { await output.joined.contains("SAFE") },
            "Password autofill should disarm after the initial auth window instead of writing credentials into a later shell prompt."
        )
        #expect(await output.joined.contains("LEAKED") == false)

        await session.stop()
    }

    @Test
    func runningSessionDoesNotRetryInteractiveAuthWithoutCachedPassword() async throws {
        let host = Host(
            name: "retry-without-password",
            address: "example.com",
            username: "root",
            auth: HostAuth(method: .password)
        )
        let output = OutputCollector()
        let states = StateCollector()
        let attemptFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-system-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: attemptFileURL) }

        let script = """
        count=$(cat '\(attemptFileURL.path)' 2>/dev/null || printf '0')
        count=$((count + 1))
        printf '%s' "$count" > '\(attemptFileURL.path)'
        printf 'Permission denied (keyboard-interactive,password).\\r\\n'
        exit 1
        """

        let session = ProcessSSHShellSession(
            host: host,
            pty: .init(columns: 80, rows: 24),
            launchConfigurationOverride: ProcessSSHShellSession.LaunchConfiguration(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                environment: ["TERM": "xterm-256color"]
            )
        )
        session.onOutput = { (data: Data) in
            Task {
                await output.append(String(decoding: data, as: UTF8.self))
            }
        }
        session.onStateChange = { state in
            Task {
                await states.append(state)
            }
        }

        try await session.start()
        #expect(
            await waitUntil(timeout: 2) { await states.last == .failed("Permission denied (keyboard-interactive,password).") },
            "Password-auth retries should stop after the first failure when there is no cached password to replay."
        )

        let attempts = try String(contentsOf: attemptFileURL, encoding: .utf8)
        #expect(attempts == "1")
    }
}

private actor OutputCollector {
    private(set) var joined = ""

    func append(_ chunk: String) {
        joined += chunk
    }
}

private actor StateCollector {
    private(set) var last: ShellSessionState = .idle

    func append(_ state: ShellSessionState) {
        last = state
    }
}

private func waitUntil(timeout: TimeInterval, condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}
