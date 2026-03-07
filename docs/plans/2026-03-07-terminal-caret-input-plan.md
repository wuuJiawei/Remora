# Terminal Caret Input Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix `TerminalView` shell-line caret blinking, caret/text alignment, and single-click cursor positioning without changing the PTY-owned input model.

**Architecture:** Keep shell editing PTY-driven. Concentrate the fix inside `TerminalView` by introducing a shared caret geometry model used by rendering, IME caret placement, and click hit testing. Extend targeted terminal tests first, then implement the minimal caret and click-path changes needed to satisfy them.

**Tech Stack:** Swift 6, AppKit, Swift Testing, custom terminal renderer in `RemoraTerminal`

---

### Task 1: Add failing caret geometry tests

**Files:**
- Modify: `Tests/RemoraTerminalTests/TerminalInputTests.swift`
- Test: `Tests/RemoraTerminalTests/TerminalInputTests.swift`

**Step 1: Write the failing test**

Add tests that assert:

- `firstRect(forCharacterRange:)` matches the same x/y origin as the terminal caret drawing model
- a test helper for caret rect / click target returns a point inside the expected cell

**Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalInputTests`
Expected: FAIL because no shared caret-rect helper or public test hook exists yet.

**Step 3: Write minimal implementation**

Add the smallest `TerminalView` test helpers needed to expose caret geometry consistently.

**Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalInputTests`
Expected: PASS for the new geometry assertions.

**Step 5: Commit**

```bash
git add Tests/RemoraTerminalTests/TerminalInputTests.swift Sources/RemoraTerminal/View/TerminalView.swift
git commit -m "test: add terminal caret geometry coverage"
```

### Task 2: Add failing caret blink tests

**Files:**
- Modify: `Tests/RemoraTerminalTests/TerminalInputTests.swift`
- Test: `Tests/RemoraTerminalTests/TerminalInputTests.swift`

**Step 1: Write the failing test**

Add tests that assert:

- focused caret starts visible
- blink visibility toggles through a test hook
- activity resets the caret to visible

**Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalInputTests`
Expected: FAIL because `TerminalView` has no blink state or reset path.

**Step 3: Write minimal implementation**

Add a minimal blink-state model and a test-only way to advance it without waiting for wall-clock time.

**Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalInputTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/RemoraTerminalTests/TerminalInputTests.swift Sources/RemoraTerminal/View/TerminalView.swift
git commit -m "test: cover terminal caret blinking"
```

### Task 3: Fix caret geometry and IME placement

**Files:**
- Modify: `Sources/RemoraTerminal/View/TerminalView.swift`
- Test: `Tests/RemoraTerminalTests/TerminalInputTests.swift`

**Step 1: Write the failing test**

If needed, add one more narrow test for caret height/vertical placement relative to renderer line height.

**Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalInputTests`
Expected: FAIL on caret geometry mismatch.

**Step 3: Write minimal implementation**

In `TerminalView`:

- add a shared caret geometry helper
- use it in `drawCursor`
- use it in `firstRect(forCharacterRange:)`
- update test point helpers to reuse the same geometry

**Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalInputTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/RemoraTerminal/View/TerminalView.swift Tests/RemoraTerminalTests/TerminalInputTests.swift
git commit -m "fix: align terminal caret geometry"
```

### Task 4: Fix click hit testing and single-click repositioning

**Files:**
- Modify: `Sources/RemoraTerminal/View/TerminalView.swift`
- Test: `Tests/RemoraTerminalTests/TerminalInputTests.swift`

**Step 1: Write the failing test**

Add tests that assert:

- single click on a known shell-line column sends the expected relative left/right movement immediately
- click target does not require a second click
- dragging after a reposition-eligible press still enters selection mode

**Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalInputTests`
Expected: FAIL because click handling still uses imprecise geometry / deferred state.

**Step 3: Write minimal implementation**

Refine `mouseDown` / `mouseDragged` / `mouseUp` handling so the shell-click path and selection path do not fight each other, while preserving double/triple click and TUI mouse-reporting behavior.

**Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalInputTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/RemoraTerminal/View/TerminalView.swift Tests/RemoraTerminalTests/TerminalInputTests.swift
git commit -m "fix: correct terminal shell click positioning"
```

### Task 5: Enable focused caret blinking in production path

**Files:**
- Modify: `Sources/RemoraTerminal/View/TerminalView.swift`
- Test: `Tests/RemoraTerminalTests/TerminalInputTests.swift`

**Step 1: Write the failing test**

Add or tighten tests that prove blink is suppressed when the view is not focused or keyboard input is disabled.

**Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalInputTests`
Expected: FAIL until the production blink gate is wired.

**Step 3: Write minimal implementation**

Add timer-backed blinking and state resets in the smallest possible focused path.

**Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalInputTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/RemoraTerminal/View/TerminalView.swift Tests/RemoraTerminalTests/TerminalInputTests.swift
git commit -m "feat: blink focused terminal caret"
```

### Task 6: Run targeted regression verification

**Files:**
- Modify: `Tests/RemoraTerminalTests/TerminalInputTests.swift`
- Test: `Tests/RemoraTerminalTests/CoreTextTerminalRendererTests.swift`

**Step 1: Run targeted terminal tests**

Run: `swift test --filter TerminalInputTests`
Expected: PASS.

**Step 2: Run renderer regression tests**

Run: `swift test --filter CoreTextTerminalRendererTests`
Expected: PASS.

**Step 3: Run one broader terminal/app regression pass**

Run: `swift test --filter TerminalRuntimeTests`
Expected: PASS.

**Step 4: Commit final verification-only follow-up if needed**

If any test-only cleanup is required, commit it separately with a focused message.
