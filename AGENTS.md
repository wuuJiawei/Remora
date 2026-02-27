# AGENTS

## Engineering principles

1. Prefer native SwiftUI built-in UI components whenever possible.
2. Only use non-SwiftUI or custom components when explicitly required by `TASKS.md` or clear technical constraints.
3. Maintain solid automated test coverage:
   - Unit tests are required for core logic.
   - Add automated app usage tests (UI/integration) whenever feasible.
   - For UI/terminal interaction changes, always run:
     `REMORA_RUN_UI_TESTS=1 swift test --filter RemoraUIAutomationTests`
     (plain `swift test` is not sufficient because UI tests are gated by env var).
4. The app logo source of truth is the repository root file: `logo.png`.
5. After each completed sub-task, create a git commit immediately (small, focused, and verifiable).
