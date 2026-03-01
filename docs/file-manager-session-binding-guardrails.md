# File Manager Session-Binding Guardrails

This note captures recurring pitfalls found in multi-session SSH + File Manager integration.

## Symptom Pattern
- Terminal shows `Connected (SSH)`, but File Manager shows `SSH client is not connected`.
- The issue may disappear after extra user interaction (for example clicking terminal), which means state eventually re-syncs but initial binding/update order is wrong.

## Primary Root Causes
- Session identity is not stable enough during tab/pane switching.
- Async remote-load tasks from an old binding complete later and overwrite UI state for a newer binding.
- Binding logic relies on string status snapshots instead of durable source-of-truth fields.

## Mandatory Design Rules
- Use **session-scoped binding key** (tab ID + pane ID), not host-only key.
- Treat `connectedSSHHost != nil` as the SSH data-plane readiness signal.
- Every async remote-load pipeline must carry a **binding generation token**.
  - Old generations must not mutate `remoteEntries`, `remoteLoadErrorMessage`, or loading state.
- Avoid broad long-running retry loops as a default fix for race conditions.
  - Prefer precise trigger points and stale-result isolation.

## Required Regression Scenarios
- File Manager is already expanded; open same SSH host in a new session; verify no `not connected` error.
- Slow connect path: open second session and wait through delayed auth/handshake; File Manager still binds correctly.
- Rapid tab switching between two active SSH sessions; each keeps its own directory state and no stale error overlay appears.
- Switch to disconnected/local pane and back to SSH pane; File Manager state restores correctly.

## Test Guidance
- Keep targeted tests first, full suite only when necessary.
- Prefer both:
  - focused unit tests for binding-generation logic
  - one focused UI/integration path that reproduces the real user flow

## Code Review Checklist (File Manager + SSH)
- [ ] Does this change introduce any async callback that can outlive the active binding?
- [ ] Is there a generation/token guard before writing view-model state?
- [ ] Is session identity explicit (tab/pane) for binding decisions?
- [ ] Are we avoiding status-string-only decisions when stronger fields exist?
