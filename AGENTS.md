# AGENTS

## Engineering principles

1. Prefer native SwiftUI built-in UI components whenever possible.
2. Only use non-SwiftUI or custom components when explicitly required by `TASKS.md` or clear technical constraints.
3. Maintain solid automated test coverage:
   - Unit tests are required for core logic.
   - Add automated app usage tests (UI/integration) whenever feasible.
   - For UI/terminal interaction changes, run only necessary automated tests based on scope (prefer targeted UI/integration tests over full suites).
   - Run the full UI automation suite (`REMORA_RUN_UI_TESTS=1 swift test --filter RemoraUIAutomationTests`) only when explicitly needed (e.g., major interaction changes, release verification, or when requested).
   - Note: plain `swift test` is not sufficient for UI automation coverage because UI tests are gated by env var.
4. The app logo source of truth is the repository root file: `logo.png`.
5. After each completed sub-task, create a git commit immediately (small, focused, and verifiable).
6. For `SystemSFTPClient` operations that should prefer SFTP and fallback to SSH (e.g., metadata updates), always use the unified helper `executeSFTPPrimaryWithSSHFallback(...)` instead of ad-hoc `do/catch` fallback code.
