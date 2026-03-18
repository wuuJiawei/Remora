# Terminal and File Manager Accordion Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a collapsible terminal section that behaves like the existing file manager disclosure, while enforcing bottom-panel accordion rules that always keep at least one panel open and still allow both panels to be open at the same time.

**Architecture:** Keep the layout orchestration in `ContentView.swift`, where the workspace detail column already decides when the file manager is shown. Extract the terminal/file-manager visibility rules into a small pure Swift helper so the accordion behavior can be tested without driving the full SwiftUI view tree. Reuse the existing disclosure-card styling and localization pattern via `tr(...)` for any new visible strings.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, RemoraApp localization helpers (`tr(...)`)

---

## Chunk 1: Visibility state model and tests

### Task 1: Define the bottom-panel visibility rules in tests first

**Files:**
- Create: `Tests/RemoraAppTests/BottomPanelVisibilityStateTests.swift`
- Modify: `Sources/RemoraApp/ContentView.swift`
- Test: `Tests/RemoraAppTests/BottomPanelVisibilityStateTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import RemoraApp

struct BottomPanelVisibilityStateTests {
    @Test
    func collapsingTerminalKeepsFileManagerOpenWhenItIsTheOnlyOtherPanel() {
        var state = BottomPanelVisibilityState(terminal: true, fileManager: false)

        state.toggleTerminal(fileManagerAvailable: true)

        #expect(state.terminal == false)
        #expect(state.fileManager == true)
    }

    @Test
    func collapsingFileManagerKeepsTerminalOpenWhenItIsTheOnlyAvailableFallback() {
        var state = BottomPanelVisibilityState(terminal: false, fileManager: true)

        state.toggleFileManager(fileManagerAvailable: true)

        #expect(state.terminal == true)
        #expect(state.fileManager == false)
    }

    @Test
    func expandingClosedPanelAllowsBothPanelsToBeOpen() {
        var state = BottomPanelVisibilityState(terminal: true, fileManager: false)

        state.toggleFileManager(fileManagerAvailable: true)

        #expect(state.terminal == true)
        #expect(state.fileManager == true)
    }

    @Test
    func fileManagerUnavailableForcesTerminalVisible() {
        var state = BottomPanelVisibilityState(terminal: false, fileManager: true)

        state.normalize(fileManagerAvailable: false)

        #expect(state.terminal == true)
        #expect(state.fileManager == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BottomPanelVisibilityStateTests`
Expected: FAIL because `BottomPanelVisibilityState` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add a tiny helper in `ContentView.swift` (or a file-local helper next to it) that owns two booleans, `toggleTerminal(fileManagerAvailable:)`, `toggleFileManager(fileManagerAvailable:)`, and `normalize(fileManagerAvailable:)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BottomPanelVisibilityStateTests`
Expected: PASS.

## Chunk 2: Hook the helper into the SwiftUI layout

### Task 2: Convert terminal into a disclosure section and wire the accordion state

**Files:**
- Modify: `Sources/RemoraApp/ContentView.swift`
- Test: `Tests/RemoraAppTests/RemoraUIAutomationTests.swift` (or equivalent existing UI-level tests if the feature is observable there)

- [ ] **Step 1: Write/extend the failing test**

Add a UI-focused regression test that verifies the terminal/file manager controls appear in an SSH session and that toggling one section keeps at least one section visible. Prefer existing test doubles and accessibility identifiers instead of introducing new app-only seams.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoraUIAutomationTests`
Expected: FAIL because the new accessibility identifiers / interactions do not exist yet.

- [ ] **Step 3: Write minimal implementation**

In `ContentView.swift`:
- Add `@State private var bottomPanelVisibility = BottomPanelVisibilityState(terminal: true, fileManager: true)` (or equivalent default that is normalized on render)
- Replace direct `isFilePanelVisible.toggle()` logic with helper-driven transitions
- Wrap `sessionContainer` in a new `terminalDisclosure`
- Keep disclosure styling aligned with `fileManagerDisclosure`
- Add accessibility identifiers for the new terminal disclosure header and the file-manager disclosure header if the tests need them
- Ensure `shouldShowFileManager == false` normalizes state so terminal stays visible
- Route any new label text through `tr(...)`, e.g. `tr("Terminal")`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RemoraUIAutomationTests`
Expected: PASS for the relevant regression coverage.

## Chunk 3: Full verification and cleanup

### Task 3: Verify diagnostics, tests, and build with fresh evidence

**Files:**
- Modify: `Sources/RemoraApp/ContentView.swift`
- Modify: `Tests/RemoraAppTests/BottomPanelVisibilityStateTests.swift`
- Modify: `Tests/RemoraAppTests/RemoraUIAutomationTests.swift` (if needed)

- [ ] **Step 1: Run language diagnostics on modified files**

Commands:
- `lsp_diagnostics` for each modified Swift file
Expected: zero errors.

- [ ] **Step 2: Run focused tests**

Run: `swift test --filter BottomPanelVisibilityStateTests`
Run: `swift test --filter RemoraUIAutomationTests`
Expected: PASS.

- [ ] **Step 3: Run the full verification suite**

Run: `swift test`
Run: `swift build`
Expected: feature-related tests pass; if the known pre-existing UTF-8 local shell test still fails, record it explicitly as an unchanged baseline failure.

- [ ] **Step 4: Re-check requirement coverage**

Confirm all of the following with code and tests:
- terminal can expand/collapse like file manager
- terminal and file manager follow accordion fallback rules
- both panels can be open simultaneously
- file-manager-unavailable states do not leave the workspace blank
- any new visible copy uses `tr(...)`
