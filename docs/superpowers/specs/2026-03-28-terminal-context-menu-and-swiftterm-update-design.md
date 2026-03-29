# Terminal Context Menu and SwiftTerm Update Design

**Status:** Approved for implementation

**Goal**

Update Remora’s embedded SwiftTerm dependency from `1.11.2` to `1.13.0`, then add a native-feeling macOS terminal interaction layer: right-click menus for the terminal surface, selection-aware copy/paste actions, and mainstream macOS keyboard shortcuts for copy, paste, and clear screen.

## Background

Remora already uses SwiftTerm as the terminal engine and wraps it through `Sources/RemoraTerminal/TerminalView.swift`, with SwiftUI integration in `Sources/RemoraApp/TerminalViewRepresentable.swift` and `Sources/RemoraApp/TerminalPaneView.swift`.

The product direction here is intentionally conservative:

- keep the terminal feeling native on macOS
- align with Terminal.app conventions before borrowing heavier terminal-emulator behaviors
- avoid inventing a separate Remora-only interaction model for basic terminal actions
- keep the implementation local to the terminal integration layer where possible

External reference points for this design:

- Apple Terminal keyboard shortcuts documentation confirms `⌘C`, `⌘V`, and `⌘K` as familiar macOS terminal actions.
- SwiftTerm `v1.13.0` is the latest stable release at the time of writing.

## Product Principles

1. **Native macOS first**
   - Remora is a macOS-only app.
   - Terminal interaction should match user expectations from Terminal.app before adding power-user variations.

2. **Terminal wrapper owns terminal behavior**
   - Context menu and keyboard handling should primarily live in `RemoraTerminal`, not be spread across unrelated SwiftUI views.
   - App-layer integration should stay thin.

3. **Selection-aware, not editor-like**
   - The terminal output surface is not a generic text editor.
   - Support `Copy`, `Paste`, `Select All`, and `Clear Screen`, but do not introduce `Cut` semantics for terminal output.

4. **Localized and theme-safe by default**
   - Every user-visible string must use `tr(...)`.
   - Any menu or UI-adjacent behavior must remain correct in both light and dark appearance.

5. **Small, reviewable delivery units**
   - Split the work into multiple commits instead of batching everything at the end.
   - Treat the dependency bump and interaction changes as separate checkpoints.

## Scope

### In scope

- Update SwiftTerm dependency references to `1.13.0`
- Verify Remora still builds and tests cleanly after the upgrade
- Add terminal right-click menu support for:
  - empty-area terminal state
  - selected-text terminal state
- Add terminal actions for:
  - `Copy`
  - `Paste`
  - `Select All`
  - `Clear Screen`
- Add macOS-style terminal shortcuts for:
  - `⌘C`
  - `⌘V`
  - `⌘K`
- Add or update automated tests that validate menu/action behavior and shortcut behavior
- Add localized strings in both English and Simplified Chinese if new copy is required

### Out of scope

- “Copy on select” behavior
- `Cut` support for terminal output
- iTerm-style smart selection or highly customized context actions
- link-specific or semantic context menu actions such as `Open Link`
- paste-history UI
- terminal command palette or advanced clipboard transforms

## UX Overview

## 1. Dependency update

Update the Swift package dependency to SwiftTerm `1.13.0`.

### Why this version

`1.13.0` is the latest stable release and includes recent macOS fixes such as caret transparency support, Home/End key fixes, redraw behavior improvements, and keyboard-protocol corrections. This is a worthwhile maintenance update even before the interaction work lands.

## 2. Terminal context menu

The terminal surface should present a right-click menu that changes based on whether text is currently selected.

### 2.1 Empty-area menu

When the user right-clicks without an active text selection, show:

- `Paste`
- `Select All`
- `Clear Screen`

### 2.2 Selection menu

When the user right-clicks with selected terminal text, show:

- `Copy`
- `Paste`
- `Select All`
- `Clear Screen`

### 2.3 Action semantics

- **Copy**
  - Copies the current terminal selection to the macOS pasteboard.
  - Only appears when a selection exists.

- **Paste**
  - Reads string content from the macOS pasteboard and sends it to the active terminal session.
  - Should be disabled when the pasteboard does not contain compatible text content.

- **Select All**
  - Selects the terminal’s available scrollback/content using the terminal engine’s selection support.

- **Clear Screen**
  - Uses real terminal clearing behavior rather than only wiping the local view.
  - Prefer an existing terminal/runtime API if already available.
  - If no dedicated clear-screen hook exists, send the most appropriate terminal clear action through the established runtime path rather than inventing a view-only fake clear.

## 3. Keyboard shortcuts

Remora should follow mainstream macOS terminal conventions:

- `⌘C` → Copy selection
- `⌘V` → Paste into terminal
- `⌘K` → Clear screen

### Shortcut rules

- `⌘C` should act as terminal copy only when the terminal pane is the focused responder and a selection exists.
- `⌘V` should paste into the focused terminal pane.
- `⌘K` should clear the focused terminal pane.
- These shortcuts must not break existing text-entry controls elsewhere in the app.
- `Ctrl-C` remains the shell interrupt signal and is unaffected.

## Architecture

The implementation should stay centered around the existing terminal wrapper layer.

### Primary files

- `Package.swift`
- `Package.resolved`
- `Sources/RemoraTerminal/TerminalView.swift`
- `Sources/RemoraApp/TerminalViewRepresentable.swift`
- `Sources/RemoraApp/TerminalPaneView.swift`
- `Sources/RemoraApp/AppKeyboardShortcuts.swift`
- `Sources/RemoraApp/RemoraAppMain.swift`
- `Sources/RemoraApp/L10n.swift`
- `Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
- `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`
- relevant terminal/app test targets under `Tests/RemoraAppTests`

### Implementation split

#### 1. SwiftTerm update

- Update the declared package dependency and lockfile
- Re-resolve packages if needed
- Run the test suite and address only upgrade-related regressions

#### 2. Terminal action surface

- Extend the terminal wrapper so it can answer questions such as:
  - whether a selection exists
  - whether paste is currently possible
  - how to execute copy/paste/select-all/clear-screen actions
- Keep the NSView/AppKit-level interaction in the terminal wrapper where the responder chain and right-click behavior are easiest to control

#### 3. SwiftUI/app integration

- Expose only the minimum state/action hooks needed by the app layer
- Reuse the existing keyboard-shortcut and menu-command structure where that improves consistency
- Ensure actions route to the currently focused terminal pane rather than to a global singleton-style terminal target

## Interaction Model Details

### Focus ownership

The active/focused terminal pane is the only pane that should respond to terminal shortcut actions. If no terminal pane is focused, Remora should fall back to existing app behavior instead of forcing terminal handling.

### Menu presentation

The context menu should use standard AppKit menu presentation so the result remains consistent with native macOS interaction. No custom-styled popover or synthetic menu should be introduced for this feature.

### Localization

Any new visible strings should be added via `tr(...)` and mirrored in:

- `Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
- `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`

Likely additions include:

- `Copy`
- `Paste`
- `Select All`
- `Clear Screen`

Only add missing keys; reuse existing localized strings when already present.

## Testing Strategy

### Automated verification

- Run `swift test` after the SwiftTerm upgrade
- Add or update tests for:
  - selection-aware menu construction
  - keyboard shortcut routing
  - clear-screen action wiring
  - localization coverage where applicable

### Manual verification

Validate in a running macOS build that:

- right-click on empty terminal surface shows the empty-area menu
- right-click on selected text shows the selection menu
- `⌘C` copies the current selection
- `⌘V` pastes clipboard text into the active terminal
- `⌘K` clears the active terminal screen
- light mode and dark mode both present the menu/actions correctly

## Risks and Mitigations

### 1. SwiftTerm upgrade regressions

Risk:
- API or behavior changes between `1.11.2` and `1.13.0` could affect Remora’s wrapper.

Mitigation:
- land the dependency update in its own commit
- run the full test suite immediately after the version bump
- keep any compatibility fixes narrowly scoped to upgrade fallout

### 2. Responder-chain ambiguity

Risk:
- keyboard actions could target the wrong pane or interfere with non-terminal text inputs.

Mitigation:
- make terminal shortcut handling explicitly focus-aware
- test behavior when the terminal is focused versus when another control is focused

### 3. Fake clear-screen behavior

Risk:
- a UI-only clear would visually wipe output without matching terminal/session behavior.

Mitigation:
- route clear-screen through the runtime/terminal action layer rather than mutating view state directly

## Commit Strategy

Deliver this work in small checkpoints instead of one final batch commit.

Planned commit sequence:

1. `docs: add terminal context menu and SwiftTerm update design`
2. `chore: update SwiftTerm to 1.13.0`
3. `feat: add terminal context menu actions`
4. `feat: add terminal copy paste shortcuts`

If implementation shows that the final two commits must be merged for correctness, keep the split as small as possible and preserve the dependency bump as its own earlier commit.

## Success Criteria

This design is complete when implementation produces all of the following:

- SwiftTerm is updated to `1.13.0`
- the app still passes `swift test`
- terminal right-click menus exist for both empty and selected states
- `⌘C`, `⌘V`, and `⌘K` work for the focused terminal pane
- terminal copy/paste behavior matches mainstream macOS expectations
- all new user-visible copy is localized
- the feature behaves correctly in both light and dark appearance
