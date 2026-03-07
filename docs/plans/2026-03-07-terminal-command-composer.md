# Terminal Command Composer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Warp-style multiline command composer for normal shell sessions, with top/bottom placement, automatic TUI hiding, and terminal fallback for full-screen terminal apps.

**Architecture:** Keep the terminal viewport as the renderer and TUI interaction surface, and introduce a SwiftUI-native composer as the only normal-shell editing surface. `TerminalRuntime` owns composer state and synchronization to the shell prompt line, while terminal-mode signals from `TerminalView` drive composer visibility.

**Tech Stack:** SwiftUI, AppKit-backed terminal view, Combine/`@Published`, Swift Testing, targeted UI automation

---

### Task 1: Expose terminal interaction mode from the terminal layer

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraTerminal/View/TerminalView.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraTerminalTests/TerminalInputTests.swift`

**Step 1: Write the failing test**

Add a test that feeds ANSI mode switches into `TerminalView` and expects a surfaced callback/state update for:

- alternate buffer on/off
- mouse reporting on/off
- application cursor mode on/off

Example shape:

```swift
@Test
func terminalViewPublishesInteractiveModeChanges() {
    let view = TerminalView(rows: 4, columns: 40)
    var snapshots: [TerminalInteractionState] = []
    view.onInteractionStateChange = { snapshots.append($0) }

    view.feed(data: Data("\u{1B}[?1049h".utf8))
    view.flushPendingOutputForTesting()

    #expect(snapshots.last?.isInteractiveTerminalMode == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter 'TerminalInputTests/terminalViewPublishesInteractiveModeChanges'
```

Expected: FAIL because the terminal view does not expose interaction-mode state yet.

**Step 3: Write minimal implementation**

In [TerminalView.swift](/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraTerminal/View/TerminalView.swift):

- add a small public state type such as `TerminalInteractionState`
- add a callback like `onInteractionStateChange`
- after parser flushes, publish current derived state
- derive `isInteractiveTerminalMode` primarily from alternate buffer, with mouse reporting and application cursor mode included in raw state

**Step 4: Run test to verify it passes**

Run:

```bash
swift test --filter 'TerminalInputTests/terminalViewPublishesInteractiveModeChanges'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraTerminal/View/TerminalView.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraTerminalTests/TerminalInputTests.swift
git commit -m "feat: expose terminal interaction state"
```

### Task 2: Add runtime-owned composer state and TUI visibility logic

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalRuntimeTests.swift`

**Step 1: Write the failing tests**

Add tests covering:

- composer is visible in normal shell mode
- composer hides when runtime receives interactive terminal mode
- draft text survives enter/exit of interactive mode

Example shape:

```swift
@Test
func commandComposerHidesInInteractiveTerminalMode() async {
    let runtime = TerminalRuntime(...)
    runtime.updateTerminalInteractionState(.init(..., isInteractiveTerminalMode: true))
    #expect(runtime.isCommandComposerVisible == false)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter '(TerminalRuntimeTests/commandComposerHidesInInteractiveTerminalMode|TerminalRuntimeTests/commandComposerDraftSurvivesInteractiveMode)'
```

Expected: FAIL because runtime does not own composer state yet.

**Step 3: Write minimal implementation**

In [TerminalRuntime.swift](/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift):

- add published properties for:
  - `commandComposerText`
  - `commandComposerSelection`
  - `isCommandComposerVisible`
  - `isInteractiveTerminalMode`
- wire `TerminalView.onInteractionStateChange` through `attach(view:)`
- preserve draft when mode changes
- keep visibility logic centralized in runtime

**Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter '(TerminalRuntimeTests/commandComposerHidesInInteractiveTerminalMode|TerminalRuntimeTests/commandComposerDraftSurvivesInteractiveMode)'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalRuntimeTests.swift
git commit -m "feat: add runtime command composer state"
```

### Task 3: Add command-composer placement setting

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/AppSettings.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/RemoraSettingsSheet.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/AppSettingsTests.swift`

**Step 1: Write the failing tests**

Add tests for:

- default placement is bottom
- saved placement round-trips through settings storage

Example:

```swift
@Test
func commandComposerPlacementDefaultsToBottom() {
    #expect(AppSettings.resolvedCommandComposerPlacement() == .bottom)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter 'AppSettingsTests'
```

Expected: FAIL because placement setting does not exist yet. If no dedicated settings test file exists, create one.

**Step 3: Write minimal implementation**

Add:

- a small placement enum
- settings key and resolver
- settings UI control in [RemoraSettingsSheet.swift](/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/RemoraSettingsSheet.swift)

Keep the UI native SwiftUI.

**Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter 'AppSettingsTests'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/AppSettings.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/RemoraSettingsSheet.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/AppSettingsTests.swift
git commit -m "feat: add command composer placement setting"
```

### Task 4: Build the SwiftUI multiline command composer view

**Files:**
- Create: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/CommandComposerView.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/CommandComposerViewTests.swift`

**Step 1: Write the failing tests**

Add tests for the view model or wrapper behavior:

- `Enter` submits
- `Shift+Enter` inserts newline
- text binding updates runtime draft
- selection/caret information is surfaced back to runtime

If the pure view is awkward to test directly, extract a tiny helper/controller and test that instead.

Example:

```swift
@Test
func commandComposerControllerSubmitsOnPlainEnter() {
    var submitted: [String] = []
    let controller = CommandComposerController(onSubmit: { submitted.append($0) })
    controller.handleKey(.return, modifiers: [])
    #expect(submitted == ["echo hi"])
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter 'CommandComposerViewTests'
```

Expected: FAIL because the composer view/controller does not exist yet.

**Step 3: Write minimal implementation**

Create [CommandComposerView.swift](/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/CommandComposerView.swift):

- use native SwiftUI/AppKit text editing primitives
- support multiline editing
- emit submit on plain `Enter`
- allow newline on `Shift+Enter`
- bind text and selection cleanly

Do not custom-build a full editor.

**Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter 'CommandComposerViewTests'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/CommandComposerView.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/CommandComposerViewTests.swift
git commit -m "feat: add multiline terminal command composer"
```

### Task 5: Sync composer edits into the shell prompt line

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalRuntimeTests.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalTestDoubles.swift`

**Step 1: Write the failing tests**

Add tests proving:

- editing composer text calls `replaceCurrentInputLine(with:cursorAt:)`
- submit sends newline and clears the draft
- multiline content is synchronized literally

Use existing recording test doubles where possible.

Example:

```swift
@Test
func commandComposerSyncReplacesCurrentInputLine() async {
    let runtime = TerminalRuntime(...)
    runtime.updateCommandComposer(text: "echo hi", cursorAt: 7)
    let commands = await recorder.commands
    #expect(commands.last == expectedSequence)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter '(TerminalRuntimeTests/commandComposerSyncReplacesCurrentInputLine|TerminalRuntimeTests/commandComposerSubmitClearsDraft)'
```

Expected: FAIL because composer-driven sync is not implemented.

**Step 3: Write minimal implementation**

In [TerminalRuntime.swift](/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift):

- add methods to update composer text/selection
- call `replaceCurrentInputLine(with:cursorAt:)` when editing changes
- add `submitCommandComposer()` that sends newline and clears state
- guard syncing so it only runs while composer is visible

**Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter '(TerminalRuntimeTests/commandComposerSyncReplacesCurrentInputLine|TerminalRuntimeTests/commandComposerSubmitClearsDraft)'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalRuntimeTests.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalTestDoubles.swift
git commit -m "feat: sync command composer with shell prompt"
```

### Task 6: Integrate composer into terminal pane layout

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalPaneView.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalViewRepresentable.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalPaneViewTests.swift`

**Step 1: Write the failing tests**

Add tests for:

- composer renders when runtime is in normal shell mode
- composer is hidden in interactive terminal mode
- composer placement changes between top and bottom

If direct view tests are difficult, use snapshot-like structural assertions or narrow hosting-controller tests.

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter 'TerminalPaneViewTests'
```

Expected: FAIL because the pane does not render the composer yet.

**Step 3: Write minimal implementation**

In [TerminalPaneView.swift](/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalPaneView.swift):

- insert `CommandComposerView`
- place it above or below the terminal according to setting
- hide it when `runtime.isCommandComposerVisible == false`
- keep terminal layout stable while switching

In [TerminalViewRepresentable.swift](/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalViewRepresentable.swift):

- ensure terminal focus is requested when composer is hidden
- avoid stealing focus from composer while it is visible

**Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter 'TerminalPaneViewTests'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalPaneView.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalViewRepresentable.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalPaneViewTests.swift
git commit -m "feat: embed command composer in terminal pane"
```

### Task 7: Restore terminal-only input cleanly for TUI sessions

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraTerminal/View/TerminalView.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalRuntimeTests.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraTerminalTests/TerminalInputTests.swift`

**Step 1: Write the failing tests**

Add tests proving:

- when interactive terminal mode starts, composer sync stops
- terminal key input continues to function for TUI mode
- returning to normal mode restores the draft without mutating the shell until the next composer edit

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter '(TerminalRuntimeTests/interactiveModeStopsComposerSync|TerminalInputTests/terminalInputStillWorksInInteractiveMode)'
```

Expected: FAIL because the handoff logic is incomplete.

**Step 3: Write minimal implementation**

- freeze composer-driven replacement while interactive mode is active
- preserve the draft locally
- keep terminal key routing intact for TUI use

Do not mix composer editing and terminal editing simultaneously.

**Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter '(TerminalRuntimeTests/interactiveModeStopsComposerSync|TerminalInputTests/terminalInputStillWorksInInteractiveMode)'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalRuntime.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraTerminal/View/TerminalView.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/TerminalRuntimeTests.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraTerminalTests/TerminalInputTests.swift
git commit -m "feat: hand off input to terminal in tui mode"
```

### Task 8: Add targeted UI automation for the new workflow

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/RemoraUIAutomationTests.swift`

**Step 1: Write the failing UI tests**

Add targeted tests for:

- composer accepts multiline command text in normal shell mode
- composer hides when a TUI session enters alternate buffer
- top/bottom placement changes layout

Prefer tests that interact with the composer by accessibility identifier instead of raw CG keyboard injection where possible.

**Step 2: Run tests to verify they fail**

Run:

```bash
REMORA_RUN_UI_TESTS=1 swift test --filter '(commandComposerWorksInShellMode|commandComposerHidesInTUIMode|commandComposerPlacementChangesLayout)'
```

Expected: FAIL because the UI automation coverage does not exist yet.

**Step 3: Write minimal implementation support**

- add accessibility identifiers for the composer container and text editor
- ensure the placement state is visible to automation
- ensure TUI transitions are externally observable

**Step 4: Run tests to verify they pass**

Run:

```bash
REMORA_RUN_UI_TESTS=1 swift test --filter '(commandComposerWorksInShellMode|commandComposerHidesInTUIMode|commandComposerPlacementChangesLayout)'
```

Expected: PASS

**Step 5: Commit**

```bash
git add /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/RemoraUIAutomationTests.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/TerminalPaneView.swift /Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/CommandComposerView.swift
git commit -m "test: add terminal command composer ui automation"
```

### Task 9: Run final scoped verification

**Files:**
- No code changes expected

**Step 1: Run terminal and app tests**

Run:

```bash
swift test --filter '(TerminalInputTests|MockSSHClientTests|TerminalRuntimeTests|TerminalPaneViewTests|AppSettingsTests|CommandComposerViewTests|TerminalDirectorySyncBridgeTests)'
```

Expected: PASS

**Step 2: Run targeted UI automation**

Run:

```bash
REMORA_RUN_UI_TESTS=1 swift test --filter '(commandComposerWorksInShellMode|commandComposerHidesInTUIMode|commandComposerPlacementChangesLayout)'
```

Expected: PASS

**Step 3: Manual verification**

Run:

```bash
swift run RemoraApp
```

Manually verify:

- normal shell shows composer
- composer supports multiline editing
- `Shift+Enter` inserts newline
- `Enter` executes
- placement switch works
- `vim` or `less` hides composer
- exiting TUI restores composer and prior draft

**Step 4: Commit any last non-code adjustments**

Only if necessary:

```bash
git add ...
git commit -m "chore: finalize terminal command composer verification"
```
