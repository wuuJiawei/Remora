# AI in Session - Design

## 1. Background and Goal

Remora will embed AI into terminal sessions as a controllable execution assistant, not just a chat box.

Core goal: provide an end-to-end loop for command work:
`Plan -> Draft -> Guard -> Run -> Reflect`

This design targets an MVP that can ship within ~2 weeks, while reserving extension points for multi-provider and advanced tool calling.

## 2. Scope

### In Scope (MVP)

- Session-bound AI chat sidecar (default mode).
- Inline prompt command (`@ai ...`) parsing and command drafting.
- Smart Assist trigger on common errors (non-intrusive suggestions).
- Natural-language intent -> structured command plan.
- Command draft generation with risk/system compatibility annotations.
- Pre-execution risk guard (rule-based) and confirmation gating.
- Post-execution reflection (explain output, goal status, next step).
- Session Context Pack builder (relevant context only).
- Provider abstraction layer with OpenAI/Anthropic/Qwen-ready contracts.
- Local audit trail for AI suggestion and execution confirmations.

### Out of Scope (for now)

- Autonomous execution without confirmation.
- Full-repository indexing / long-term RAG memory.
- Multi-host parallel orchestration.
- Local/offline model runtime.

## 3. Product Interaction Modes

### 3.1 Mode A: Chat Sidecar (Default)

A right/bottom side panel bound to current terminal session.

AI output is structured into 3 blocks:

1. Intent explanation (what and why).
2. Command drafts (copy / run with confirm).
3. Risk notes (needs confirm, rollback advice).

This is the safest default for rollout.

### 3.2 Mode B: Inline Prompt

Shell-like prompt command:

- User input: `@ai 查一下这个目录下最大的10个文件并按大小排序`
- AI output: executable draft commands with variants.

Result is printed into sidecar and optionally inserted into command line buffer (never auto-run).

### 3.3 Mode C: Smart Assist

Passive assistant triggered by output pattern and exit code:

- `permission denied` -> suggest `id`, `ls -l`, `sudo -l`
- `No such file` -> suggest `pwd`, `ls`, `$PATH` checks

Smart Assist does not seize focus and can be dismissed.

## 4. High-Level Architecture

```
Session UI (TerminalPane)
  -> SessionAIAssistantCoordinator
      -> AIContextPackBuilder
      -> AIOrchestrator (Plan/Draft/Guard/Reflect)
          -> AIProviderSDK (multi-provider)
          -> AIToolGateway (system/file/command tools)
          -> CommandRiskEngine
      -> AIAuditStore
```

### 4.1 Components

- `SessionAIAssistantCoordinator`
  - Session-scoped state machine.
  - Wires UI events to orchestration flow.

- `AIContextPackBuilder`
  - Builds request-time context with token budget.
  - Filters irrelevant data before model call.

- `AIOrchestrator`
  - Implements the lifecycle: Plan -> Draft -> Guard -> Run -> Reflect.
  - Owns retries/timeouts/fallback prompts.

- `AIProviderSDK`
  - Unified adapter for OpenAI/Anthropic/Qwen.
  - Supports text + tool-calling + streaming.

- `AIToolGateway`
  - Controlled tool surface exposed to model.
  - Includes allowlist and per-tool limits.

- `CommandRiskEngine`
  - Static command checks and policy decision:
    - `allow`
    - `needs_confirmation`
    - `block`

- `AIAuditStore`
  - Stores intent, suggestions, user confirms, execution result summary.

## 5. Session Context Pack

Only relevant context is packed. No full-screen dump.

### 5.1 Static fields

- host
- os
- shell
- user
- isRoot
- cwd
- environment tag (`prod`, `staging`, `dev`)
- network egress flag (if known)

### 5.2 Dynamic fields (clipped)

- recent commands (N=20) with exit code
- latest output tail (200-500 lines; hard token cap)
- directory summary (top 50 entries + key files)
- user-selected snippets (explicit opt-in only)

### 5.3 Intent constraints

- e.g. `read_only=true`
- `no_sudo=true`
- `must_support_busybox=true`

### 5.4 Packing policy

- Priority by relevance: intent-related > recency > breadth.
- Hard size budgets per section.
- Secret redaction before outbound call.

## 6. AI Provider SDK

Unified protocol in Swift:

```swift
protocol LLMProvider {
    func chat(messages: [LLMMessage], options: LLMOptions) async throws -> LLMCompletion
    func toolCall(messages: [LLMMessage], tools: [LLMTool], options: LLMOptions) async throws -> LLMToolResult
    func stream(messages: [LLMMessage], tools: [LLMTool]?, options: LLMOptions) async throws -> AsyncThrowingStream<LLMStreamEvent, Error>
}
```

Session-level config:

- provider/model
- temperature
- system policy preset
- tool permissions (`read_file`, `run_command`, etc.)

If provider lacks native tool-call: use JSON schema fallback parser.

## 7. Tool Calling Contract

### 7.1 Read-only tools

- `get_system_info()`
- `list_dir(path, max=200)`
- `read_file(path, start, limit)`
- `tail_file(path, lines)`
- `find_files(query, scope)`
- `search_in_file(path, pattern, max_matches)`

### 7.2 Execution tools

- `run_command(cmd, require_confirm=true, timeout=30s)`
- optional: `sftp_upload`, `sftp_download` (phase 2)

### 7.3 Safety tools

- `risk_assess(cmd)`
- `redact(text)`

All tool outputs must be normalized to structured JSON payloads for deterministic UI rendering.

## 8. Guardrails and Security Policy

Default posture: safe and explainable.

### 8.1 Policy tiers

- `ReadOnlyDefault`
  - AI drafts commands only.
  - No execution without explicit user action.

- `ConfirmedWrite`
  - Write/destructive operations require explicit confirmation.

- `ProdStrict`
  - Blocks dangerous classes (`rm -rf`, `mkfs`, wildcard recursive chmod/chown, `curl | sh`).

### 8.2 Detection rules (initial)

- destructive patterns (`rm -rf`, `dd`, `mkfs`, fork bombs)
- sensitive data exposure (`~/.ssh`, `~/.aws/credentials`, `printenv` full dump)
- suspicious outbound download/exec flows
- broad scope ops on `/` or global wildcard recursive actions

### 8.3 Confirmation UX

- clear risk label: low/medium/high
- show impacted path/scope
- require explicit confirm action for high risk

## 9. Flow Details

### 9.1 Plan

Input: user intent + context pack.
Output: ordered plan steps + validation checkpoints.

### 9.2 Draft

Output 1-3 command variants:

- conservative
- balanced
- high-performance (if applicable)

Each variant includes:

- OS compatibility (Ubuntu/CentOS/BusyBox/macOS)
- sudo requirement
- risk level

### 9.3 Guard

Static analyze candidate command and policy-check before execution.

### 9.4 Run

Execution only via controlled tool with timeout and captured output.

### 9.5 Reflect

AI explains output, states whether goal met, and proposes next step.

## 10. UI/UX Notes

- Sidecar is session-bound and survives tab switches with same session id.
- Smart Assist cards appear inline in sidecar feed; never auto-focus steal.
- Inline prompt keeps terminal-native feel and writes result back to sidecar timeline.
- All run actions include visible “from AI suggestion” badge for transparency.

## 11. Data, Privacy, and Audit

- Redact secrets before provider call.
- Keep a local, user-visible audit timeline:
  - user intent
  - AI drafts
  - risk decision
  - user confirmation
  - execution summary (cmd hash + exit code + duration)

- Keep full stdout/stderr storage opt-in (off by default for privacy).

## 12. Testing Strategy

- Unit:
  - `AIContextPackBuilderTests`
  - `CommandRiskEngineTests`
  - `AIOrchestratorFlowTests`
  - provider adapter schema tests

- Integration:
  - sidecar -> draft -> confirm -> run -> reflect happy path
  - blocked dangerous command path
  - prod strict policy path

- UI automation:
  - sidecar send/receive
  - inline `@ai` command
  - smart assist trigger on mocked error output

## 13. Rollout Plan

Phase 1 (MVP): Sidecar + Plan/Draft/Guard/Reflect + basic provider + rule guard.

Phase 2: Smart Assist depth improvements, richer tools, policy presets by environment.

Phase 3: knowledge templates/RAG, multi-session orchestration, optional local models.

## 14. Open Questions

- Should prod/staging/dev tag be user-defined per host or auto-inferred?
- Should confirmation require typed phrase for high risk or UI-only toggle?
- How long should audit history persist by default?
- What is the minimum provider set at first release (OpenAI-only or multi-provider)?
