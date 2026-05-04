import Foundation

public protocol RemoteShellIntegrationInstalling: Sendable {
    func ensureInstalled(for host: Host) async throws
}

public actor OpenSSHRemoteShellIntegrationInstaller: RemoteShellIntegrationInstalling {
    public static let shared = OpenSSHRemoteShellIntegrationInstaller()

    static let installCommand = """
    umask 077
    config_dir="$HOME/.config/remora"
    fish_dir="$HOME/.config/fish/conf.d"
    mkdir -p "$config_dir" "$fish_dir"

    cat >"$config_dir/shell-integration.bash" <<'REMORA_BASH'
    if [ -n "${REMORA_SHELL_INTEGRATION_LOADED:-}" ]; then
      return 0 2>/dev/null || exit 0
    fi
    REMORA_SHELL_INTEGRATION_LOADED=1
    __remora_host_name() { hostname -f 2>/dev/null || hostname 2>/dev/null || printf localhost; }
    __remora_emit_cwd() { printf '\\033]7;file://%s%s\\007' "$(__remora_host_name)" "$PWD"; }
    __remora_emit_prompt_start() { printf '\\033]133;A\\007'; }
    __remora_pre_prompt() { __remora_emit_cwd; __remora_emit_prompt_start; }
    case ";${PROMPT_COMMAND-};" in
      *";__remora_pre_prompt;"*) ;;
      *)
        __remora_prompt_command="${PROMPT_COMMAND-}"
        __remora_prompt_command="${__remora_prompt_command%"${__remora_prompt_command##*[![:space:];]}"}"
        PROMPT_COMMAND="${__remora_prompt_command:+$__remora_prompt_command; }__remora_pre_prompt"
        ;;
    esac
    __remora_emit_cwd
    REMORA_BASH

    cat >"$config_dir/shell-integration.zsh" <<'REMORA_ZSH'
    if [[ -n "${REMORA_SHELL_INTEGRATION_LOADED:-}" ]]; then
      return 0
    fi
    export REMORA_SHELL_INTEGRATION_LOADED=1
    function __remora_host_name() {
      hostname -f 2>/dev/null || hostname 2>/dev/null || print -r -- localhost
    }
    function __remora_emit_cwd() {
      printf '\\033]7;file://%s%s\\007' "$(__remora_host_name)" "$PWD"
    }
    function __remora_emit_prompt_start() {
      printf '\\033]133;A\\007'
    }
    function __remora_precmd() {
      __remora_emit_cwd
      __remora_emit_prompt_start
    }
    autoload -Uz add-zsh-hook 2>/dev/null || true
    if whence add-zsh-hook >/dev/null 2>&1; then
      add-zsh-hook chpwd __remora_emit_cwd
      add-zsh-hook precmd __remora_precmd
    else
      chpwd_functions=(__remora_emit_cwd ${chpwd_functions[@]})
      precmd_functions=(${precmd_functions[@]} __remora_precmd)
    fi
    __remora_emit_cwd
    REMORA_ZSH

    cat >"$fish_dir/remora.fish" <<'REMORA_FISH'
    status --is-interactive; or exit
    function __remora_emit_cwd --on-variable PWD
        set -l __remora_host_name (hostname -f 2>/dev/null; or hostname 2>/dev/null; or printf localhost)
        printf '\\033]7;file://%s%s\\007' "$__remora_host_name" "$PWD"
    end
    function __remora_emit_prompt_start --on-event fish_prompt
        printf '\\033]133;A\\007'
    end
    __remora_emit_cwd
    REMORA_FISH

    ensure_block() {
      file="$1"
      body="$2"
      touch "$file"
      if ! grep -Fq '# >>> Remora shell integration >>>' "$file"; then
        {
          printf '\n# >>> Remora shell integration >>>\n'
          printf '%s\n' "$body"
          printf '# <<< Remora shell integration <<<\n'
        } >> "$file"
      fi
    }

    ensure_block "$HOME/.bashrc" '[ -r "$HOME/.config/remora/shell-integration.bash" ] && . "$HOME/.config/remora/shell-integration.bash"'
    ensure_block "$HOME/.bash_profile" '[ -r "$HOME/.config/remora/shell-integration.bash" ] && . "$HOME/.config/remora/shell-integration.bash"'
    ensure_block "$HOME/.profile" '[ -r "$HOME/.config/remora/shell-integration.bash" ] && . "$HOME/.config/remora/shell-integration.bash"'
    ensure_block "$HOME/.zshrc" '[ -r "$HOME/.config/remora/shell-integration.zsh" ] && source "$HOME/.config/remora/shell-integration.zsh"'
    printf 'remora-shell-integration-installed\n'
    """

    public init() {}

    public func ensureInstalled(for host: Host) async throws {
        let compatibilityProfile = await SSHCompatibilityProfileStore.shared.cachedProfile(for: host) ?? SSHCompatibilityProfile()
        guard let launch = await ProcessSSHShellSession.makeRemoteCommandLaunchConfiguration(
            for: host,
            command: Self.installCommand,
            compatibilityProfile: compatibilityProfile
        ) else {
            throw SSHError.connectionFailed("shell integration installer could not build launch configuration")
        }

        try await Self.run(launch)
    }

    private static func run(_ launch: ProcessSSHShellSession.LaunchConfiguration) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executablePath)
        process.arguments = launch.arguments
        if !launch.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = errorText?.isEmpty == false ? errorText! : "installer exited with status \(process.terminationStatus)"
            throw SSHError.connectionFailed(reason)
        }
    }
}
