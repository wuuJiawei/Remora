import Foundation
import Darwin

public actor OpenSSHProcessClient: SSHTransportClientProtocol {
    private var connectedHost: Host?

    public init() {}

    public func connect(to host: Host) async throws {
        connectedHost = host
    }

    public func openShell(pty: PTYSize) async throws -> SSHTransportSessionProtocol {
        guard let host = connectedHost else {
            throw SSHError.notConnected
        }
        return ProcessSSHShellSession(host: host, pty: pty)
    }

    public func disconnect() async {
        connectedHost = nil
    }
}

public typealias SystemSSHClient = OpenSSHProcessClient

public final class ProcessSSHShellSession: SSHTransportSessionProtocol, @unchecked Sendable {
    struct LaunchConfiguration {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
    }

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (ShellSessionState) -> Void)?

    private let host: Host
    private let launchConfigurationOverride: LaunchConfiguration?
    private var pty: PTYSize
    private var process: Process?
    private var masterHandle: FileHandle?
    private var masterFileDescriptor: Int32?
    private let credentialStore = CredentialStore()
    private let stateQueue = DispatchQueue(label: "io.lighting-tech.remora.ssh.session")

    public init(host: Host, pty: PTYSize) {
        self.host = host
        self.launchConfigurationOverride = nil
        self.pty = pty
    }

    init(host: Host, pty: PTYSize, launchConfigurationOverride: LaunchConfiguration?) {
        self.host = host
        self.launchConfigurationOverride = launchConfigurationOverride
        self.pty = pty
    }

    public func start() async throws {
        let shouldStart = stateQueue.sync { process == nil }
        guard shouldStart else {
            return
        }

        let proc = Process()
        let launch = await makeLaunchConfiguration()
        proc.executableURL = URL(fileURLWithPath: launch.executablePath)
        proc.arguments = launch.arguments
        if !launch.environment.isEmpty {
            proc.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
        }

        let descriptors = try createPseudoTerminal(initialSize: pty)
        let masterFD = descriptors.master
        let slaveFD = descriptors.slave
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let stdinHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let stdoutFD = dup(slaveFD)
        let stderrFD = dup(slaveFD)
        guard stdoutFD >= 0, stderrFD >= 0 else {
            let reason = "ssh shell setup failed: \(String(cString: strerror(errno)))"
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            try? stdinHandle.close()
            if stdoutFD >= 0 { _ = Darwin.close(stdoutFD) }
            if stderrFD >= 0 { _ = Darwin.close(stderrFD) }
            throw SSHError.connectionFailed(reason)
        }

        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: true)
        proc.standardInput = stdinHandle
        proc.standardOutput = stdoutHandle
        proc.standardError = stderrHandle

        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onOutput?(data)
        }

        proc.terminationHandler = { [weak self] task in
            self?.cleanupHandles()
            guard let self else { return }

            if task.terminationStatus == 0 {
                self.onStateChange?(.stopped)
                return
            }

            let message = "ssh exited with status \(task.terminationStatus)"
            self.onOutput?(Data((message + "\r\n").utf8))
            self.onStateChange?(.failed(message))
        }

        do {
            try proc.run()
        } catch {
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            cleanupHandles()
            onStateChange?(.failed(error.localizedDescription))
            throw SSHError.connectionFailed(error.localizedDescription)
        }

        stateQueue.sync {
            process = proc
            self.masterHandle = masterHandle
            masterFileDescriptor = masterFD
        }

        onStateChange?(.running)
    }

    public func write(_ data: Data) async throws {
        try writeSync(data)
    }

    public func resize(_ size: PTYSize) async throws {
        pty = size
        let state = stateQueue.sync { (masterFileDescriptor, process?.processIdentifier) }
        guard let masterFileDescriptor = state.0 else {
            throw SSHError.notConnected
        }

        var windowSize = makeWindowSize(from: size)
        let resizeResult = ioctl(masterFileDescriptor, TIOCSWINSZ, &windowSize)
        guard resizeResult == 0 else {
            let reason = String(cString: strerror(errno))
            throw SSHError.connectionFailed("resize failed: \(reason)")
        }

        if let processIdentifier = state.1, processIdentifier > 0 {
            _ = kill(pid_t(processIdentifier), SIGWINCH)
        }
    }

    public func stop() async {
        let currentProcess = stateQueue.sync { process }
        guard let currentProcess else {
            cleanupHandles()
            onStateChange?(.stopped)
            return
        }

        if currentProcess.isRunning {
            currentProcess.terminate()
            return
        }
        cleanupHandles()
        onStateChange?(.stopped)
    }

    private func writeSync(_ data: Data) throws {
        guard let masterHandle = stateQueue.sync(execute: { masterHandle }) else {
            throw SSHError.notConnected
        }

        do {
            try masterHandle.write(contentsOf: data)
        } catch {
            throw SSHError.connectionFailed("write failed: \(error.localizedDescription)")
        }
    }

    private func cleanupHandles() {
        let currentHandle = stateQueue.sync { () -> FileHandle? in
            let handle = masterHandle
            masterHandle = nil
            masterFileDescriptor = nil
            process = nil

            return handle
        }

        currentHandle?.readabilityHandler = nil
        try? currentHandle?.close()
    }

    private func createPseudoTerminal(initialSize: PTYSize) throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = makeWindowSize(from: initialSize)
        let result = openpty(&master, &slave, nil, nil, &windowSize)
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            throw SSHError.connectionFailed("openpty failed: \(reason)")
        }
        return (master: master, slave: slave)
    }

    private func makeWindowSize(from size: PTYSize) -> winsize {
        winsize(
            ws_row: UInt16(clamping: size.rows),
            ws_col: UInt16(clamping: size.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
    }

    private func makeLaunchConfiguration() async -> LaunchConfiguration {
        if let launchConfigurationOverride {
            return launchConfigurationOverride
        }

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

        if host.auth.method == .password,
           hasStoredPassword,
           let password = storedPassword,
           let launch = Self.makePasswordLaunchConfiguration(for: host, password: password)
        {
            return launch
        }

        let useConnectionReuse = SSHConnectionReusePolicy.shouldUseConnectionReuse(
            authMethod: host.auth.method,
            hasStoredPassword: hasStoredPassword
        )
        return Self.makeStandardLaunchConfiguration(for: host, useConnectionReuse: useConnectionReuse)
    }

    static func makeSSHArguments(for host: Host, useConnectionReuse: Bool = true) -> [String] {
        var args: [String] = [
            "-tt",
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        if useConnectionReuse {
            args.append(contentsOf: SSHConnectionReuse.masterOptions(for: host))
        }

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
            args.append(contentsOf: ["-o", "NumberOfPasswordPrompts=1"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        args.append(makeRemoteShellIntegrationCommand())
        return args
    }

    static func makeRemoteShellIntegrationCommand() -> String {
        """
        REMORA_SHELL_INTEGRATION=1; shell="${SHELL:-/bin/sh}";
        case "$shell" in
          */bash|bash)
            tmp="${TMPDIR:-/tmp}/remora-bash-$$.rc"
            cat >"$tmp" <<'REMORA_BASH_RC'
        if [ -r ~/.bash_profile ]; then . ~/.bash_profile; elif [ -r ~/.profile ]; then . ~/.profile; fi
        if [ -r ~/.bashrc ]; then . ~/.bashrc; fi
        __remora_emit_cwd() { printf '\u{001B}]7;file://%s%s\u{001B}\\' "${HOSTNAME:-$(hostname 2>/dev/null || printf localhost)}" "$PWD"; }
        PROMPT_COMMAND="__remora_emit_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        __remora_emit_cwd
        REMORA_BASH_RC
            exec "$shell" --noprofile --rcfile "$tmp" -i
            ;;
          */zsh|zsh)
            tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/remora-zsh.XXXXXX")" || exit 1
            cat >"$tmpdir/.zshenv" <<'REMORA_ZSHENV'
        if [ -r ~/.zshenv ]; then source ~/.zshenv; fi
        REMORA_ZSHENV
            cat >"$tmpdir/.zprofile" <<'REMORA_ZPROFILE'
        if [ -r ~/.zprofile ]; then source ~/.zprofile; fi
        REMORA_ZPROFILE
            cat >"$tmpdir/.zshrc" <<'REMORA_ZSHRC'
        if [ -r ~/.zshrc ]; then source ~/.zshrc; fi
        function __remora_emit_cwd() { printf '\u{001B}]7;file://%s%s\u{001B}\\' "${HOST:-$(hostname 2>/dev/null || printf localhost)}" "$PWD"; }
        autoload -Uz add-zsh-hook 2>/dev/null || true
        if whence add-zsh-hook >/dev/null 2>&1; then
          add-zsh-hook precmd __remora_emit_cwd
        else
          precmd_functions=(__remora_emit_cwd ${precmd_functions[@]})
        fi
        __remora_emit_cwd
        REMORA_ZSHRC
            cat >"$tmpdir/.zlogin" <<'REMORA_ZLOGIN'
        if [ -r ~/.zlogin ]; then source ~/.zlogin; fi
        REMORA_ZLOGIN
            ZDOTDIR="$tmpdir" exec "$shell" -il
            ;;
          *)
            exec "$shell" -il
            ;;
        esac
        """
    }

    static func makeStandardLaunchConfiguration(for host: Host, useConnectionReuse: Bool = true) -> LaunchConfiguration {
        wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(for: host, useConnectionReuse: useConnectionReuse),
            environment: [:]
        )
    }

    static func makePasswordLaunchConfiguration(
        for host: Host,
        password: String,
        sshpassPath: String? = defaultSSHPassPath(),
        askPassScriptPath: String? = ensureAskPassScriptPath()
    ) -> LaunchConfiguration? {
        let wrapped = wrappedSSHLaunchConfiguration(
            sshArguments: makeSSHArguments(for: host, useConnectionReuse: false),
            environment: [:]
        )

        if let sshpassPath {
            return LaunchConfiguration(
                executablePath: sshpassPath,
                arguments: ["-e", wrapped.executablePath] + wrapped.arguments,
                environment: ["SSHPASS": password]
            )
        }

        guard let askPassScriptPath else { return nil }
        return LaunchConfiguration(
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

    private static func wrappedSSHLaunchConfiguration(
        sshArguments: [String],
        environment: [String: String]
    ) -> LaunchConfiguration {
        let sshPath = "/usr/bin/ssh"
        let environment = mergedTerminalEnvironment(environment)

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/script") {
            return LaunchConfiguration(
                executablePath: "/usr/bin/script",
                arguments: ["-q", "/dev/null", sshPath] + sshArguments,
                environment: environment
            )
        }

        return LaunchConfiguration(
            executablePath: sshPath,
            arguments: sshArguments,
            environment: environment
        )
    }

    private static func mergedTerminalEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        let inheritedTerm = ProcessInfo.processInfo.environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            environment["TERM"] = (inheritedTerm?.isEmpty == false ? inheritedTerm : nil) ?? "xterm-256color"
        }

        return environment
    }

    private static func defaultSSHPassPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func ensureAskPassScriptPath() -> String? {
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
}
