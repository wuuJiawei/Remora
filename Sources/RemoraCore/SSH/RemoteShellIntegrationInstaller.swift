import Foundation

public actor RemoteShellIntegrationInstaller {
    public static let shared = RemoteShellIntegrationInstaller()

    static let installCommand = """
    umask 077
    config_dir="$HOME/.config/remora"
    fish_dir="$HOME/.config/fish/conf.d"
    mkdir -p "$config_dir" "$fish_dir"

    cat >"$config_dir/shell-integration.bash" <<'REMORA_BASH'
    if [ -z "${BASH_VERSION:-}" ]; then
      return 0 2>/dev/null || exit 0
    fi
    case $- in
      *i*) ;;
      *) return 0 2>/dev/null || exit 0 ;;
    esac
    if [ ! -t 1 ]; then
      return 0 2>/dev/null || exit 0
    fi
    if [ -n "${REMORA_SHELL_INTEGRATION_LOADED:-}" ]; then
      return 0 2>/dev/null || exit 0
    fi
    REMORA_SHELL_INTEGRATION_LOADED=1
    __remora_host_name() { hostname -f 2>/dev/null || hostname 2>/dev/null || printf localhost; }
    __remora_emit_cwd() { printf '\033]7;file://%s%s\007' "$(__remora_host_name)" "$PWD"; }
    __remora_emit_prompt_start() { printf '\033]133;A\007'; }
    __remora_pre_prompt() { __remora_emit_cwd; __remora_emit_prompt_start; }
    case ";${PROMPT_COMMAND-};" in
      *";__remora_pre_prompt;"*) ;;
      *)
        __remora_prompt_command="${PROMPT_COMMAND-}"
        __remora_prompt_command="${__remora_prompt_command%"${__remora_prompt_command##*[![:space:];]}"}"
        PROMPT_COMMAND="${__remora_prompt_command:+$__remora_prompt_command; }__remora_pre_prompt"
        ;;
    esac
    REMORA_BASH

    cat >"$config_dir/shell-integration.zsh" <<'REMORA_ZSH'
    if [[ ! -o interactive ]] || [[ ! -t 1 ]]; then
      return 0 2>/dev/null || exit 0
    fi
    if [[ -n "${REMORA_SHELL_INTEGRATION_LOADED:-}" ]]; then
      return 0
    fi
    export REMORA_SHELL_INTEGRATION_LOADED=1
    function __remora_host_name() {
      hostname -f 2>/dev/null || hostname 2>/dev/null || print -r -- localhost
    }
    function __remora_emit_cwd() {
      printf '\033]7;file://%s%s\007' "$(__remora_host_name)" "$PWD"
    }
    function __remora_emit_prompt_start() {
      printf '\033]133;A\007'
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
    REMORA_ZSH

    cat >"$fish_dir/remora.fish" <<'REMORA_FISH'
    status --is-interactive; or return
    function __remora_emit_cwd --on-variable PWD
        set -l __remora_host_name (hostname -f 2>/dev/null; or hostname 2>/dev/null; or printf localhost)
        printf '\033]7;file://%s%s\007' "$__remora_host_name" "$PWD"
    end
    function __remora_pre_prompt --on-event fish_prompt
        __remora_emit_cwd
        printf '\033]133;A\007'
    end
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

    bash_loader='if [ -n "${BASH_VERSION:-}" ]; then
      case $- in
        *i*) [ -r "$HOME/.config/remora/shell-integration.bash" ] && . "$HOME/.config/remora/shell-integration.bash" ;;
      esac
    fi'
    zsh_loader='if [[ -o interactive ]] && [[ -t 1 ]] && [[ -r "$HOME/.config/remora/shell-integration.zsh" ]]; then
      source "$HOME/.config/remora/shell-integration.zsh"
    fi'
    ensure_block "$HOME/.bashrc" "$bash_loader"
    ensure_block "$HOME/.bash_profile" "$bash_loader"
    ensure_block "$HOME/.profile" "$bash_loader"
    ensure_block "$HOME/.zshrc" "$zsh_loader"
    printf 'remora-shell-integration-installed\n'
    """

    public init() {}

    public func ensureInstalled(using executor: any RemoteCommandExecutorProtocol) async throws {
        let result = try await executor.execute(
            RemoteCommandRequest(
                executable: .shell(Self.installCommand),
                replayPolicy: .never,
                timeout: .seconds(10)
            )
        )
        guard result.exitStatus == 0 else {
            throw RemoteOperationError(
                category: .command,
                code: "shell_integration_install_failed",
                safeDiagnosticMessage: "Shell integration installer exited with status \(result.exitStatus)"
            )
        }
    }
}
