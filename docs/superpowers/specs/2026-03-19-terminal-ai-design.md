# Terminal AI Design

**Status:** Approved for implementation

**Goal**

Add a session-bound AI assistant to Remora’s terminal workflow that feels native to a terminal app: provider-first configuration in Settings, model selection under the chosen provider, custom endpoint support for OpenAI-compatible and Claude-compatible APIs, and an in-terminal assistant surface that helps users explain output, draft commands, and recover from common shell failures without hijacking the terminal.

## Background

Remora is already a native macOS terminal workspace with SSH, SFTP, quick commands, and SwiftTerm-backed session panes. The AI feature should extend that workflow rather than replace it.

The product direction should borrow the good parts of tools like OpenCode and other provider-managed AI apps:

- configure the provider first
- then configure/select the model
- keep endpoint/auth details explicit
- make AI available inside the working surface instead of sending the user to a separate page

At the same time, Remora is not a coding agent IDE or a general-purpose chat app. The feature should stay scoped to terminal assistance.

## Product Principles

1. **Terminal first, AI second**
   - The terminal remains the primary surface.
   - AI stays collapsed by default and is opt-in per session.

2. **Provider-first configuration**
   - Users choose the provider first.
   - Model options are derived from that provider.
   - Custom endpoints are supported without forcing users into one vendor.

3. **Transparent command help**
   - AI suggests and explains.
   - It never silently executes commands.
   - Any “Run” action is explicit and visible.

4. **Session-scoped context**
   - AI uses the current session’s working directory and recent output.
   - It does not try to be a global memory system or repo-wide agent in this release.

5. **Secure by default**
   - API keys live in Keychain-backed credential storage.
   - Outbound context is intentionally limited.
   - Secret-heavy data is not sent automatically.

## Scope

### In scope

- Global AI settings pane in `RemoraSettingsSheet`
- Built-in mainstream providers plus a custom provider option
- Provider-specific model suggestions and a custom model field
- Custom base URL support
- Custom API format selection for custom providers:
  - OpenAI-compatible
  - Claude-compatible
- Session-bound assistant drawer in each terminal pane
- Prompt-based terminal help for:
  - explaining output
  - suggesting next commands
  - drafting commands from natural-language intent
- Non-intrusive smart assist card for obvious terminal failures
- Command insertion and optional confirmed execution through `TerminalRuntime`
- Local per-session assistant history

### Out of scope

- autonomous multi-step tool use
- background agent orchestration
- long-term memory or vector search
- repository indexing
- multiple saved custom provider profiles
- streaming transport for the first version
- provider-specific advanced options such as temperature/top-p tuning per vendor

## UX Overview

## 1. Settings: new `AI` pane

Add a dedicated `AI` pane to `RemoraSettingsSheet`, alongside `General`, `Shortcuts`, and `Advanced`.

### 1.1 Sections

#### AI availability

- **Enable Terminal AI** toggle
- helper copy explaining that AI assistance is disabled globally when turned off

#### Provider

- **Provider** picker
- built-in options:
  - OpenAI
  - Anthropic
  - OpenRouter
  - DeepSeek
  - Qwen / DashScope
  - Ollama
  - Custom

#### Connection

- **API format** picker
  - hidden for fixed built-in providers when the format is implied
  - visible for `Custom`
  - values:
    - OpenAI Compatible
    - Claude Compatible
- **Base URL** text field
  - prefilled for built-in providers
  - editable so users can point a built-in provider at a proxy if they want
- **API key** secure field
  - stored in `CredentialStore`
  - settings UI shows status (`Not Set` / `Saved in Keychain`)

#### Model

- **Model** text field
- preset suggestion chips/buttons based on selected provider
- users can still type a custom model id

#### Assistant behavior

- **Show smart assist on command failures** toggle
- **Include working directory in AI context** toggle
- **Include recent terminal output in AI context** toggle
- **Max recent output lines** stepper (safe bounded range)

### 1.2 Why this shape

This matches the provider → model flow the user requested, keeps advanced network details available without cluttering every session, and follows the existing settings-card structure already used by Remora.

## 2. Terminal integration

### 2.1 Entry point

Each `TerminalPaneView` gets a small AI toggle button in the terminal header. It should visually match the existing quick-actions row and not dominate the header.

### 2.2 Assistant drawer

When opened, the terminal pane splits into:

- main terminal content
- trailing AI drawer with a fixed comfortable width

The drawer is session-bound and collapsible. If the user switches tabs or panes, each pane remembers its own assistant state and message history.

### 2.3 Drawer contents

- session status summary
  - current provider / model
  - current working directory
- quick actions
  - Explain latest output
  - Suggest next command
  - Fix last error
- prompt composer
- assistant timeline

Each assistant response is rendered as structured cards:

- **Summary** — short explanation of what the AI thinks
- **Commands** — one or more suggested commands with purpose and risk label
- **Warnings** — caveats or follow-up guidance

Each command card supports:

- **Insert** — place command text into the terminal input buffer without executing
- **Run** — confirm and execute through `TerminalRuntime`
- **Copy** — copy command text

### 2.4 Smart assist

When the recent terminal output strongly suggests an error (`permission denied`, `command not found`, `no such file or directory`, etc.), show a subtle smart-assist banner under the terminal header.

The banner should:

- not steal focus
- be dismissible
- offer one-tap actions into the AI drawer, such as `Explain` and `Suggest fix`

## 3. Context policy

The assistant request should be built from a constrained context pack:

- session mode (`Local` / `SSH`)
- host label if connected over SSH
- working directory if enabled
- clipped transcript tail if enabled
- user request

### Guardrails

- do not automatically send full environment variables
- do not automatically send SSH passwords, private key contents, or entire config files
- redact obvious secret patterns from transcript snippets when possible
- keep transcript size bounded by line count and total characters

## Provider and API model

## Built-in provider mapping

| Provider | Default API format | Default base URL | Model behavior |
| --- | --- | --- | --- |
| OpenAI | OpenAI-compatible | `https://api.openai.com/v1` | preset list + custom entry |
| Anthropic | Claude-compatible | `https://api.anthropic.com` | preset list + custom entry |
| OpenRouter | OpenAI-compatible | `https://openrouter.ai/api/v1` | preset list + custom entry |
| DeepSeek | OpenAI-compatible | `https://api.deepseek.com/v1` | preset list + custom entry |
| Qwen / DashScope | OpenAI-compatible | `https://dashscope.aliyuncs.com/compatible-mode/v1` | preset list + custom entry |
| Ollama | OpenAI-compatible | `http://localhost:11434/v1` | custom/local model entry |
| Custom | user-selected | user-entered | fully manual |

## Custom provider rule

Custom providers support exactly two explicit wire formats:

- **OpenAI Compatible**
- **Claude Compatible**

This deliberately avoids a sprawling “supports everything” UI while still covering the most common proxy/self-hosted setups.

## Architecture

For this release, the AI stack should live in `RemoraApp`, because it is tightly coupled to session UI behavior and terminal interaction.

### New app-layer units

- `AISettings.swift`
  - provider enum
  - api format enum
  - model presets
  - UserDefaults keys / helpers
- `AISettingsStore.swift`
  - reads/writes non-secret AI settings
  - stores API keys via `CredentialStore`
- `TerminalAIModels.swift`
  - request/response models
  - command suggestion models
- `TerminalAIService.swift`
  - performs HTTP requests to OpenAI-compatible or Claude-compatible endpoints
  - normalizes response into Remora’s assistant model
- `TerminalAIAssistantCoordinator.swift`
  - session-bound state, prompt submission, smart assist, and command actions
- `TerminalAIAssistantView.swift`
  - drawer UI

### Modified app-layer units

- `AppSettings.swift`
  - add AI-related settings keys and defaults
- `RemoraSettingsSheet.swift`
  - add `AI` pane and settings card UI
- `WorkspaceViewModel.swift`
  - give each `TerminalPaneModel` its own assistant coordinator / state
- `TerminalPaneView.swift`
  - add AI button, smart-assist banner, and assistant drawer layout
- `TerminalRuntime.swift`
  - expose safe APIs for inserting or running assistant-suggested commands

### Dependencies

- use `RemoraCore.Security.CredentialStore` for API key persistence
- keep network transport in Foundation / `URLSession`
- reuse `VisualStyle` for all new UI colors so light/dark mode works naturally

## Request / response contract

The app should ask the model for a structured JSON payload so the UI can stay deterministic.

Suggested normalized response shape:

```json
{
  "summary": "Short explanation of what is happening.",
  "commands": [
    {
      "command": "ls -lah",
      "purpose": "Inspect the current directory contents.",
      "risk": "safe"
    }
  ],
  "warnings": [
    "Avoid running recursive delete commands without checking the path first."
  ]
}
```

If decoding fails, the UI may fall back to a plain-text assistant message, but the prompt should strongly prefer valid JSON.

## Execution policy

- AI never auto-runs commands.
- `Insert` is always safe.
- `Run` always uses a confirmation prompt.
- The confirmation prompt should show the exact command being executed.

This keeps the assistant useful without pretending to be a fully autonomous agent.

## Localization and appearance

- all new user-facing strings must use `tr(...)`
- add/update entries in both:
  - `Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
  - `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`
- all new UI must use theme-aware colors from `VisualStyle` or platform semantic colors
- verify both light and dark appearances before completion

## Testing strategy

### Unit tests

- `AISettingsStoreTests`
  - provider/model persistence
  - custom format persistence
  - keychain-backed API key behavior
- `TerminalAIServiceTests`
  - OpenAI-compatible request building
  - Claude-compatible request building
  - response decoding and fallback handling
- `TerminalAIAssistantCoordinatorTests`
  - disabled-state gating
  - context building
  - session history isolation
  - smart assist detection

### Integration / UI coverage

- settings AI pane appears and saves values
- AI toggle opens/closes the drawer in a terminal pane
- assistant can insert command text into terminal input
- confirmed run sends the command to `TerminalRuntime`

## Acceptance criteria

The feature is complete when all of the following are true:

- Remora has a dedicated `AI` settings pane
- users can configure provider, model, base URL, and API key
- custom providers support OpenAI-compatible and Claude-compatible formats
- each terminal pane can open its own assistant drawer
- assistant can explain output and suggest commands using session context
- command suggestions can be inserted, copied, and run with explicit confirmation
- smart assist appears for common failure patterns without stealing focus
- all new user-facing strings are localized in English and Simplified Chinese
- the UI works in both light and dark mode
- tests cover persistence, transport shaping, and session assistant behavior
