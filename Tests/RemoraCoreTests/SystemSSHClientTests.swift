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
        #expect(!args.contains("ControlMaster=auto"))
        #expect(!args.contains(where: { $0.hasPrefix("ControlPath=/tmp/") }))
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
    func controlPathIncludesPurposeAndHostIdentity() {
        let host = Host(
            name: "prod",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )

        let shellPath = SSHConnectionReuse.controlPath(for: host, purpose: .shell)
        let sftpPath = SSHConnectionReuse.controlPath(for: host, purpose: .sftp)

        #expect(shellPath != sftpPath)
        #expect(shellPath.contains(host.id.uuidString.prefix(8)))
        #expect(shellPath.contains("-shell-"))
        #expect(sftpPath.contains("-sftp-"))
    }

    @Test
    func controlPathSeparatesHostsAndConnectionSettings() {
        let hostID = UUID()
        let host = Host(
            id: hostID,
            name: "prod",
            address: String(repeating: "a", count: 100) + ".example.com",
            port: 22,
            username: String(repeating: "deploy", count: 20),
            auth: HostAuth(method: .agent)
        )
        var changedAddress = host
        changedAddress.address = String(repeating: "b", count: 100) + ".example.com"
        var changedPort = host
        changedPort.port = 2222
        let differentHost = Host(
            name: host.name,
            address: host.address,
            port: host.port,
            username: host.username,
            auth: host.auth
        )

        let path = SSHConnectionReuse.controlPath(for: host, purpose: .shell)

        #expect(path == SSHConnectionReuse.controlPath(for: host, purpose: .shell))
        #expect(path != SSHConnectionReuse.controlPath(for: changedAddress, purpose: .shell))
        #expect(path != SSHConnectionReuse.controlPath(for: changedPort, purpose: .shell))
        #expect(path != SSHConnectionReuse.controlPath(for: differentHost, purpose: .shell))
        #expect(path.utf8.count < 104)
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
        #expect(command.contains("\\033]133;A\\007"))
        #expect(command.contains("--on-event fish_prompt"))
        #expect(command.contains("status --is-interactive; or return"))
        #expect(command.contains("status --is-interactive; or exit") == false)
        #expect(command.contains("__remora_prompt_command=\"${PROMPT_COMMAND-}\""))
        #expect(command.contains("PROMPT_COMMAND=\"${__remora_prompt_command:+$__remora_prompt_command; }__remora_pre_prompt\""))
        #expect(command.contains("precmd_functions=(${precmd_functions[@]} __remora_precmd)"))
        #expect(command.contains("if [ -z \"${BASH_VERSION:-}\" ]; then"))
        #expect(command.contains("if [[ ! -o interactive ]] || [[ ! -t 1 ]]; then"))
        #expect(command.contains("*i*) [ -r \"$HOME/.config/remora/shell-integration.bash\" ]"))
    }

    @Test
    func installedShellIntegrationsDoNotPolluteNonInteractiveOutput() throws {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-shell-integration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let installResult = try runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", OpenSSHRemoteShellIntegrationInstaller.installCommand],
            environment: ["HOME": homeURL.path]
        )
        #expect(installResult.status == 0, "Installer failed: \(installResult.stderr)")

        let bashScriptPath = homeURL.appendingPathComponent(".config/remora/shell-integration.bash").path
        let zshScriptPath = homeURL.appendingPathComponent(".config/remora/shell-integration.zsh").path
        let fishScriptPath = homeURL.appendingPathComponent(".config/fish/conf.d/remora.fish").path
        let installedScripts = try [bashScriptPath, zshScriptPath, fishScriptPath].map {
            try String(contentsOfFile: $0, encoding: .utf8)
        }
        for script in installedScripts {
            #expect(script.contains("\n__remora_emit_cwd\n") == false)
        }
        #expect(installedScripts[2].contains("function __remora_pre_prompt --on-event fish_prompt\n    __remora_emit_cwd"))

        let cases = [
            ("/bin/sh", ["-c", ". \"$REMORA_SCRIPT\"; printf REMORA_OK"], bashScriptPath),
            ("/bin/bash", ["--noprofile", "--norc", "-c", ". \"$REMORA_SCRIPT\"; printf REMORA_OK"], bashScriptPath),
            ("/bin/zsh", ["-f", "-c", "source \"$REMORA_SCRIPT\"; printf REMORA_OK"], zshScriptPath),
        ]

        for (executablePath, arguments, scriptPath) in cases {
            let result = try runProcess(
                executablePath: executablePath,
                arguments: arguments,
                environment: ["REMORA_SCRIPT": scriptPath]
            )
            #expect(result.status == 0, "\(executablePath) failed: \(result.stderr)")
            #expect(result.stdout == "REMORA_OK", "\(executablePath) polluted stdout: \(result.stdout.debugDescription)")
        }
    }

    @Test
    func remoteShellIntegrationInstallCommandTrimsTrailingBashPromptSeparators() {
        let command = OpenSSHRemoteShellIntegrationInstaller.installCommand

        #expect(command.contains("__remora_prompt_command=\"${PROMPT_COMMAND-}\""))
        #expect(command.contains("__remora_prompt_command=\"${__remora_prompt_command%\"${__remora_prompt_command##*[![:space:];]}\"}\""))
        #expect(command.contains("PROMPT_COMMAND=\"${__remora_prompt_command:+$__remora_prompt_command; }__remora_pre_prompt\""))
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
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
    func runningSessionNeverAutofillsStoredLoginPasswordIntoOTPChallenge() async throws {
        let host = Host(
            name: "otp-test",
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
                    "printf 'One-time password:'; if IFS= read -r -t 0.5 code; then printf '\\r\\nLEAKED\\r\\n'; else printf '\\r\\nSAFE\\r\\n'; fi"
                ],
                environment: ["TERM": "xterm-256color"]
            ),
            interactivePasswordAutofillOverride: "stored-login-password"
        )
        session.onOutput = { data in
            Task {
                await output.append(String(decoding: data, as: UTF8.self))
            }
        }
        try await session.start()

        #expect(
            await waitUntil(timeout: 2) { await output.joined.contains("SAFE") },
            "A saved login password must not be submitted to an OTP keyboard-interactive prompt."
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
            await waitUntil(timeout: 2) { await output.joined.contains("Permission denied (keyboard-interactive,password).") },
            "Password-auth retries should stop after the first failure when there is no cached password to replay."
        )

        let attempts = try String(contentsOf: attemptFileURL, encoding: .utf8)
        #expect(attempts == "1")
    }

    @Test
    func buildsPortForwardArgumentsForLocalTunnel() {
        let host = Host(
            name: "db",
            address: "example.com",
            port: 22,
            username: "deploy",
            auth: HostAuth(method: .agent)
        )
        let preset = HostPortForwardPreset(
            name: "postgres",
            localAddress: "127.0.0.1",
            localPort: 5432,
            remoteAddress: "10.0.0.5",
            remotePort: 5432
        )

        let launch = OpenSSHLaunchBuilder.makePortForwardLaunchConfiguration(
            for: host,
            preset: preset,
            storedPassword: nil
        )

        #expect(launch?.arguments.contains("-N") == true)
        #expect(launch?.arguments.contains("-L") == true)
        #expect(launch?.arguments.contains("127.0.0.1:5432:10.0.0.5:5432") == true)
        #expect(launch?.arguments.contains("ExitOnForwardFailure=yes") == true)
        #expect(launch?.arguments.contains(where: { $0.contains("-port-forward-") }) == true)
        #expect(launch?.arguments.contains("-tt") == false)
    }

    @Test
    func shellLaunchPlanUsesConnectionReusePolicy() {
        let agentHost = Host(
            name: "agent-shell",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )
        let keyHost = Host(
            name: "key-shell",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .privateKey, keyReference: "/tmp/id_ed25519")
        )
        let passwordHost = Host(
            name: "password-shell",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .password, passwordReference: "password-ref")
        )

        let agentPlan = ProcessSSHShellSession.makeShellLaunchPlan(for: agentHost, storedPassword: nil)
        let keyPlan = ProcessSSHShellSession.makeShellLaunchPlan(for: keyHost, storedPassword: nil)
        let missingPasswordPlan = ProcessSSHShellSession.makeShellLaunchPlan(
            for: passwordHost,
            storedPassword: nil,
            sshpassPath: nil,
            askPassScriptPath: nil
        )
        let emptyPasswordPlan = ProcessSSHShellSession.makeShellLaunchPlan(
            for: passwordHost,
            storedPassword: "",
            sshpassPath: nil,
            askPassScriptPath: nil
        )
        let storedPasswordPlan = ProcessSSHShellSession.makeShellLaunchPlan(
            for: passwordHost,
            storedPassword: "stored-password",
            sshpassPath: "/usr/bin/false",
            askPassScriptPath: nil
        )

        for plan in [agentPlan, keyPlan, missingPasswordPlan, emptyPasswordPlan] {
            #expect(plan.configuration.arguments.contains("ControlMaster=auto"))
            #expect(plan.configuration.arguments.contains("ControlPersist=no"))
            #expect(plan.configuration.arguments.contains(where: { $0.hasPrefix("ControlPath=") }))
        }
        #expect(!storedPasswordPlan.configuration.arguments.contains("ControlMaster=auto"))
        #expect(!storedPasswordPlan.configuration.arguments.contains(where: { $0.hasPrefix("ControlPath=") }))
    }

    @Test
    func disablingConnectionReuseRemovesOnlyControlOptions() {
        let configuration = ProcessSSHShellSession.LaunchConfiguration(
            executablePath: "/usr/bin/ssh",
            arguments: [
                "-tt",
                "-o", "ControlMaster=auto",
                "-o", "StrictHostKeyChecking=ask",
                "-o", "ControlPath=/tmp/remora.sock",
                "-o", "ControlPersist=no",
                "ubuntu@example.com",
            ],
            environment: ["TERM": "xterm-256color"]
        )

        let fallback = ProcessSSHShellSession.launchConfigurationWithoutConnectionReuse(configuration)

        #expect(fallback.arguments == [
            "-tt",
            "-o", "StrictHostKeyChecking=ask",
            "ubuntu@example.com",
        ])
        #expect(fallback.environment == configuration.environment)
    }

    @Test
    func controlMasterFailureRetriesOnceWithoutReuseOptions() async throws {
        let host = Host(
            name: "reuse-fallback",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )
        let output = OutputCollector()
        let states = StateCollector()
        let argumentsLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-reuse-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: argumentsLogURL) }
        let script = """
        printf '%s\n' "$*" >> '\(argumentsLogURL.path)'
        case " $* " in
          *ControlMaster=auto*) printf 'mux_client_request_session: session request failed: Session open refused by peer\r\n'; exit 1 ;;
          *) printf 'READY\r\n'; sleep 1 ;;
        esac
        """
        let session = ProcessSSHShellSession(
            host: host,
            pty: .init(columns: 80, rows: 24),
            launchConfigurationOverride: ProcessSSHShellSession.LaunchConfiguration(
                executablePath: "/bin/sh",
                arguments: [
                    "-c", script, "remora-reuse-test",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=/tmp/remora-reuse-test.sock",
                    "-o", "ControlPersist=no",
                    "-o", "StrictHostKeyChecking=ask",
                ],
                environment: ["TERM": "xterm-256color"]
            )
        )
        session.onOutput = { data in
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

        let becameReady = await waitUntil(timeout: 2) { await output.joined.contains("READY") }
        let attempts = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let capturedOutput = await output.joined
        let capturedState = await states.last
        #expect(becameReady, "Captured state: \(capturedState); output: \(capturedOutput)")
        #expect(attempts.count == 2, "Attempts: \(attempts); state: \(capturedState); output: \(capturedOutput)")
        guard attempts.count == 2 else {
            await session.stop()
            return
        }
        #expect(attempts[0].contains("ControlMaster=auto"))
        #expect(!attempts[1].contains("ControlMaster="))
        #expect(!attempts[1].contains("ControlPath="))
        #expect(!attempts[1].contains("ControlPersist="))
        #expect(attempts[1].contains("StrictHostKeyChecking=ask"))
        await session.stop()
    }

    @Test
    func repeatedControlMasterFailureDoesNotRetryIndefinitely() async throws {
        let host = Host(
            name: "reuse-loop-guard",
            address: "example.com",
            username: "ubuntu",
            auth: HostAuth(method: .agent)
        )
        let states = StateCollector()
        let output = OutputCollector()
        let attemptFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-reuse-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: attemptFileURL) }
        let script = """
        count=$(cat '\(attemptFileURL.path)' 2>/dev/null || printf '0')
        count=$((count + 1))
        printf '%s' "$count" > '\(attemptFileURL.path)'
        printf 'mux_client_request_session: session request failed: Session open refused by peer\r\n'
        exit 1
        """
        let session = ProcessSSHShellSession(
            host: host,
            pty: .init(columns: 80, rows: 24),
            launchConfigurationOverride: ProcessSSHShellSession.LaunchConfiguration(
                executablePath: "/bin/sh",
                arguments: [
                    "-c", script, "remora-reuse-loop-test",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=/tmp/remora-reuse-loop-test.sock",
                    "-o", "ControlPersist=no",
                ],
                environment: ["TERM": "xterm-256color"]
            )
        )
        session.onStateChange = { state in
            Task {
                await states.append(state)
            }
        }
        session.onOutput = { data in
            Task {
                await output.append(String(decoding: data, as: UTF8.self))
            }
        }

        try await session.start()

        let failed = await waitUntil(timeout: 2) {
            if case .failed = await states.last { return true }
            return false
        }
        let attempts = try String(contentsOf: attemptFileURL, encoding: .utf8)
        let capturedOutput = await output.joined
        let capturedState = await states.last
        #expect(failed, "State: \(capturedState); output: \(capturedOutput)")
        #expect(attempts == "2", "Output: \(capturedOutput)")
    }

    @Test
    func detectsControlMasterSessionOpenFailures() {
        #expect(ProcessSSHShellSession.isControlMasterFailure("mux_client_request_session: session request failed: Session open refused by peer"))
        #expect(ProcessSSHShellSession.isControlMasterFailure("control socket connect(/tmp/remora.sock): Connection refused"))
        #expect(!ProcessSSHShellSession.isControlMasterFailure("Permission denied (publickey,password)."))
    }

    @Test
    func validatesLocalPortAvailability() {
        #expect(PortForwardValidation.isValidPort(22))
        #expect(PortForwardValidation.isValidPort(0) == false)
        #expect(PortForwardValidation.isValidPort(65_536) == false)
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
