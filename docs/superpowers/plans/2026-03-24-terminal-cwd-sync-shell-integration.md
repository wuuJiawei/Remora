# Terminal CWD Sync Shell Integration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore SSH terminal ↔ FTP panel directory sync without injecting visible `pwd` commands into the shell.

**Architecture:** Reuse the existing `TerminalRuntime` OSC 7 parser and make the remote shell proactively emit cwd updates from shell hooks that live only for the current session. Keep cwd tracking event-driven: shell integration becomes the primary path, while explicit `changeDirectory(to:)` remains the only command-driven fallback already in product code today.

**Tech Stack:** Swift, Combine, OpenSSH/local PTY runtime, ANSI/OSC terminal escape sequences, XCTest

---

## File map

- Modify: `Sources/RemoraApp/TerminalRuntime.swift`
  - Add session-scoped shell integration bootstrap flow and state.
  - Enable/disable cwd reporting when terminal sync is active.
- Modify: `Sources/RemoraApp/TerminalDirectorySyncBridge.swift`
  - Ensure sync enablement activates shell-based cwd tracking for SSH runtimes only.
- Possibly modify: `Sources/RemoraCore/SSH/LocalShellClient.swift` or SSH transport/session startup files if bootstrap injection belongs lower in stack.
- Test: `Tests/RemoraAppTests/TerminalRuntimeTests.swift`
  - Add regression tests for shell-integration-based cwd updates and no visible `pwd` injection.
- Test: `Tests/RemoraAppTests/TerminalDirectorySyncBridgeTests.swift`
  - Add/adjust sync tests to verify FTP panel follows cwd updates produced by shell integration.

## Chunk 1: Runtime shell integration bootstrap

### Task 1: Define the failing runtime behavior

**Files:**
- Modify: `Tests/RemoraAppTests/TerminalRuntimeTests.swift`

- [ ] **Step 1: Write failing test for SSH connect not emitting visible pwd while still enabling cwd updates**
- [ ] **Step 2: Run targeted runtime test to verify failure is for missing cwd event updates, not test mistakes**
- [ ] **Step 3: Write failing test for terminal-entered `cd` updating `workingDirectory` through emitted OSC 7/current-dir events**
- [ ] **Step 4: Run targeted runtime tests and confirm failure**

### Task 2: Implement session-scoped shell bootstrap

**Files:**
- Modify: `Sources/RemoraApp/TerminalRuntime.swift`

- [ ] **Step 1: Add minimal runtime state to know whether shell integration bootstrap has already been injected for the active session**
- [ ] **Step 2: Add a bootstrap command/script generator for supported shells (zsh/bash first; fish optional only if already practical in current code structure)**
- [ ] **Step 3: Inject shell integration only after SSH shell is connected and only when cwd tracking is enabled**
- [ ] **Step 4: Ensure bootstrap is session-scoped and never writes remote dotfiles**
- [ ] **Step 5: Ensure bootstrap emits cwd updates via OSC 7 on prompt/directory changes and does not echo visible `pwd` lines**

### Task 3: Verify runtime behavior

**Files:**
- Test: `Tests/RemoraAppTests/TerminalRuntimeTests.swift`

- [ ] **Step 1: Run targeted runtime tests**
- [ ] **Step 2: Run the runtime suite repeatedly to shake out races**

## Chunk 2: File panel sync wiring

### Task 4: Wire sync toggle to shell-based tracking

**Files:**
- Modify: `Sources/RemoraApp/TerminalDirectorySyncBridge.swift`
- Test: `Tests/RemoraAppTests/TerminalDirectorySyncBridgeTests.swift`

- [ ] **Step 1: Write/adjust failing bridge test that enabling sync causes future shell cwd changes to update the FTP panel without visible `pwd`**
- [ ] **Step 2: Run targeted bridge test to verify failure**
- [ ] **Step 3: Implement the minimal bridge/runtime enablement path so sync-on attaches shell-based tracking for SSH only**
- [ ] **Step 4: Verify existing no-extra-`cd` and no-visible-`pwd` guarantees stay intact**

### Task 5: Verification

**Files:**
- Modify: `Sources/RemoraApp/TerminalRuntime.swift`
- Modify: `Sources/RemoraApp/TerminalDirectorySyncBridge.swift`
- Test: `Tests/RemoraAppTests/TerminalRuntimeTests.swift`
- Test: `Tests/RemoraAppTests/TerminalDirectorySyncBridgeTests.swift`

- [ ] **Step 1: Run `lsp_diagnostics` on every modified file**
- [ ] **Step 2: Run `swift test --filter TerminalRuntimeTests`**
- [ ] **Step 3: Run `swift test --filter TerminalDirectorySyncBridgeTests`**
- [ ] **Step 4: Run `swift test`**
- [ ] **Step 5: If any test fails, return to the failing task and fix root cause before continuing**
