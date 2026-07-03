import Foundation

struct OpenSSHLaunchConfiguration: Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
}

struct OpenSSHLaunchPlan: Sendable {
    var configuration: OpenSSHLaunchConfiguration
    var interactivePasswordAutofill: String?
}

enum OpenSSHLaunchBuilder {
    static func makeShellLaunchPlan(
        for host: Host,
        storedPassword: String?,
        sshpassPath: String? = defaultSSHPassPath(),
        askPassScriptPath: String? = ensureAskPassScriptPath(),
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile(),
        skipAutoPasswordDelivery: Bool = false
    ) -> OpenSSHLaunchPlan {
        if host.auth.method == .password, let password = storedPassword, !password.isEmpty {
            if !skipAutoPasswordDelivery, let launch = makePasswordLaunchConfiguration(
                for: host,
                password: password,
                sshpassPath: sshpassPath,
                askPassScriptPath: sshpassPath == nil ? nil : askPassScriptPath,
                compatibilityProfile: compatibilityProfile
            ) {
                return OpenSSHLaunchPlan(configuration: launch, interactivePasswordAutofill: nil)
            }

            return OpenSSHLaunchPlan(
                configuration: makeStandardLaunchConfiguration(
                    for: host,
                    useConnectionReuse: false,
                    compatibilityProfile: compatibilityProfile
                ),
                interactivePasswordAutofill: password
            )
        }

        return OpenSSHLaunchPlan(
            configuration: makeStandardLaunchConfiguration(
                for: host,
                useConnectionReuse: false,
                compatibilityProfile: compatibilityProfile
            ),
            interactivePasswordAutofill: nil
        )
    }

    static func makePortForwardLaunchConfiguration(
        for host: Host,
        preset: HostPortForwardPreset,
        storedPassword: String?,
        sshpassPath: String? = defaultSSHPassPath(),
        askPassScriptPath: String? = ensureAskPassScriptPath(),
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) -> OpenSSHLaunchConfiguration? {
        guard preset.kind == .local else { return nil }

        if host.auth.method == .password,
           let password = storedPassword,
           !password.isEmpty,
           let launch = makePasswordLaunchConfiguration(
                for: host,
                password: password,
                allocateTTY: false,
                compatibilityProfile: compatibilityProfile,
                extraArguments: portForwardArguments(for: preset)
           ) {
            return launch
        }

        let useConnectionReuse = SSHConnectionReusePolicy.shouldUseConnectionReuse(
            authMethod: host.auth.method,
            hasStoredPassword: storedPassword?.isEmpty == false
        )
        return wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(
                for: host,
                useConnectionReuse: useConnectionReuse,
                allocateTTY: false,
                connectionReusePurpose: .portForward,
                remoteCommand: nil,
                compatibilityProfile: compatibilityProfile,
                extraArguments: portForwardArguments(for: preset)
            ),
            environment: [:],
            wrapInScript: false
        )
    }

    static func makeSSHArguments(
        for host: Host,
        useConnectionReuse: Bool = true,
        allocateTTY: Bool = true,
        connectionReusePurpose: SSHConnectionReuse.Purpose = .shell,
        remoteCommand: String? = nil,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile(),
        extraArguments: [String] = []
    ) -> [String] {
        var args: [String] = [
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        if allocateTTY {
            args.insert("-tt", at: 0)
        }
        if useConnectionReuse {
            args.append(contentsOf: SSHConnectionReuse.masterOptions(for: host, purpose: connectionReusePurpose))
        }
        args.append(contentsOf: compatibilityProfile.additionalSSHOptions())
        args.append(contentsOf: extraArguments)

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=keyboard-interactive,password"])
            args.append(contentsOf: ["-o", "NumberOfPasswordPrompts=3"])
            args.append(contentsOf: ["-o", "PubkeyAuthentication=no"])
            args.append(contentsOf: ["-o", "GSSAPIAuthentication=no"])
            args.append(contentsOf: ["-o", "KbdInteractiveAuthentication=yes"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        if let remoteCommand, !remoteCommand.isEmpty {
            args.append(remoteCommand)
        }
        return args
    }

    static func makeStandardLaunchConfiguration(
        for host: Host,
        useConnectionReuse: Bool = true,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) -> OpenSSHLaunchConfiguration {
        wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(
                for: host,
                useConnectionReuse: useConnectionReuse,
                compatibilityProfile: compatibilityProfile
            ),
            environment: [:],
            wrapInScript: true
        )
    }

    static func makeRemoteCommandLaunchConfiguration(
        for host: Host,
        command: String,
        credentialStore: CredentialStore = CredentialStore(),
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile()
    ) async -> OpenSSHLaunchConfiguration? {
        let storedPassword: String? = if host.auth.method == .password,
                                         let passwordReference = host.auth.passwordReference,
                                         !passwordReference.isEmpty,
                                         let password = await credentialStore.secret(for: passwordReference),
                                         !password.isEmpty {
            password
        } else {
            nil
        }
        let hasStoredPassword = storedPassword != nil
        let useConnectionReuse = SSHConnectionReusePolicy.shouldUseConnectionReuse(
            authMethod: host.auth.method,
            hasStoredPassword: hasStoredPassword
        )

        if host.auth.method == .password,
           let password = storedPassword,
           let launch = makePasswordLaunchConfiguration(
                for: host,
                password: password,
                remoteCommand: command,
                allocateTTY: false,
                compatibilityProfile: compatibilityProfile
           ) {
            return launch
        }

        return wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(
                for: host,
                useConnectionReuse: useConnectionReuse,
                allocateTTY: false,
                connectionReusePurpose: .remoteCommand,
                remoteCommand: command,
                compatibilityProfile: compatibilityProfile
            ),
            environment: [:],
            wrapInScript: false
        )
    }

    static func makePasswordLaunchConfiguration(
        for host: Host,
        password: String,
        sshpassPath: String? = defaultSSHPassPath(),
        askPassScriptPath: String? = ensureAskPassScriptPath(),
        remoteCommand: String? = nil,
        allocateTTY: Bool = true,
        compatibilityProfile: SSHCompatibilityProfile = SSHCompatibilityProfile(),
        extraArguments: [String] = []
    ) -> OpenSSHLaunchConfiguration? {
        if let sshpassPath {
            let sshArgs = makeSSHArguments(
                for: host,
                useConnectionReuse: false,
                allocateTTY: allocateTTY,
                remoteCommand: remoteCommand,
                compatibilityProfile: compatibilityProfile,
                extraArguments: extraArguments
            )
            return OpenSSHLaunchConfiguration(
                executablePath: sshpassPath,
                arguments: ["-e", "/usr/bin/ssh"] + sshArgs,
                environment: mergedTerminalEnvironment(["SSHPASS": password])
            )
        }

        let wrapped = wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(
                for: host,
                useConnectionReuse: false,
                allocateTTY: allocateTTY,
                remoteCommand: remoteCommand,
                compatibilityProfile: compatibilityProfile,
                extraArguments: extraArguments
            ),
            environment: [:],
            wrapInScript: allocateTTY
        )

        guard let askPassScriptPath else { return nil }
        return OpenSSHLaunchConfiguration(
            executablePath: wrapped.executablePath,
            arguments: wrapped.arguments,
            environment: [
                "SSH_ASKPASS": askPassScriptPath,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "remora-askpass",
                "REMORA_SSH_PASSWORD": password,
            ]
        )
    }

    static func wrappedSSHLaunchConfiguration(
        sshArguments: [String],
        environment: [String: String],
        wrapInScript: Bool
    ) -> OpenSSHLaunchConfiguration {
        let sshPath = "/usr/bin/ssh"
        let environment = mergedTerminalEnvironment(environment)

        if wrapInScript, FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            return OpenSSHLaunchConfiguration(
                executablePath: "/usr/bin/script",
                arguments: ["-q", "/dev/null", sshPath] + sshArguments,
                environment: environment
            )
        }

        return OpenSSHLaunchConfiguration(
            executablePath: sshPath,
            arguments: sshArguments,
            environment: environment
        )
    }

    static func mergedTerminalEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        if environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            environment["TERM"] = "xterm-256color"
        }
        return environment
    }

    static func defaultSSHPassPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func ensureAskPassScriptPath() -> String? {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-ssh-askpass.sh")

        if FileManager.default.fileExists(atPath: scriptURL.path) {
            return scriptURL.path
        }

        let script = """
        #!/bin/sh
        printf '%s\\n' "${REMORA_SSH_PASSWORD}"
        """
        guard let scriptData = script.data(using: .utf8) else {
            return nil
        }

        do {
            try scriptData.write(to: scriptURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return scriptURL.path
        } catch {
            return nil
        }
    }

    private static func portForwardArguments(for preset: HostPortForwardPreset) -> [String] {
        let localTarget = "\(preset.localAddress):\(preset.localPort):\(preset.remoteAddress):\(preset.remotePort)"
        return [
            "-N",
            "-L", localTarget,
            "-o", "ExitOnForwardFailure=yes",
        ]
    }
}
