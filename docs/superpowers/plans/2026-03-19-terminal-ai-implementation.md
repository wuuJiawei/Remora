# Terminal AI Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a session-bound Terminal AI assistant for Remora with provider-first settings, model selection, custom OpenAI-compatible/Claude-compatible endpoints, and safe command suggestion actions inside each terminal pane.

**Architecture:** Keep the feature in `RemoraApp` because the first release is primarily a session UI workflow. Persist non-secret settings in `UserDefaults`, store API keys in `CredentialStore`, add a per-pane assistant coordinator for state, and talk to model providers through a small `URLSession`-based service that normalizes OpenAI-compatible and Claude-compatible responses into a shared response model.

**Tech Stack:** Swift 6, SwiftUI, Foundation/URLSession, RemoraCore `CredentialStore`, Swift Testing, existing `VisualStyle` and localization helpers.

---

## Chunk 1: AI settings foundation

### Task 1: Define AI settings models and persistence keys

**Files:**
- Create: `Sources/RemoraApp/AISettings.swift`
- Modify: `Sources/RemoraApp/AppSettings.swift`
- Test: `Tests/RemoraAppTests/AppSettingsTests.swift`

- [ ] **Step 1: Add provider and API format enums**

Define built-in providers, custom API format cases, default base URLs, and model suggestions in `AISettings.swift`.

- [ ] **Step 2: Add AI-related settings keys and safe defaults**

Add keys for enablement, active provider, base URL, API format, selected model, smart assist toggle, transcript toggle, working-directory toggle, and transcript line budget in `AppSettings.swift`.

- [ ] **Step 3: Extend settings clamping helpers**

Add bounded helper(s) for transcript line budget and any other numeric AI settings.

- [ ] **Step 4: Add persistence tests**

Update `AppSettingsTests.swift` to validate defaults and clamping.

- [ ] **Step 5: Run targeted tests**

Run: `swift test --filter AppSettingsTests`

- [ ] **Step 6: Commit**

Commit foundation settings changes and tests.

## Chunk 2: Secure AI settings store and provider transport

### Task 2: Implement AI settings store with Keychain-backed API key storage

**Files:**
- Create: `Sources/RemoraApp/AISettingsStore.swift`
- Test: `Tests/RemoraAppTests/AISettingsStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Cover reading defaults, writing provider/model/base URL values, and storing/removing API keys through `CredentialStore`.

- [ ] **Step 2: Implement store API**

Create a small observable/store type that bridges `UserDefaults` and `CredentialStore` without storing secrets in plain text.

- [ ] **Step 3: Run targeted tests**

Run: `swift test --filter AISettingsStoreTests`

- [ ] **Step 4: Commit**

Commit the store and tests.

### Task 3: Implement normalized AI transport service

**Files:**
- Create: `Sources/RemoraApp/TerminalAIModels.swift`
- Create: `Sources/RemoraApp/TerminalAIService.swift`
- Test: `Tests/RemoraAppTests/TerminalAIServiceTests.swift`

- [ ] **Step 1: Write failing transport tests**

Cover OpenAI-compatible request shaping, Claude-compatible request shaping, response decoding, and JSON-fallback handling.

- [ ] **Step 2: Define shared assistant response models**

Add normalized summary / command / warnings models plus any request context types.

- [ ] **Step 3: Implement service transport**

Use `URLSession` to build vendor-specific requests and decode the response into the normalized assistant model.

- [ ] **Step 4: Run targeted tests**

Run: `swift test --filter TerminalAIServiceTests`

- [ ] **Step 5: Commit**

Commit AI transport code and tests.

## Chunk 3: Session coordinator and terminal runtime hooks

### Task 4: Add per-pane assistant coordinator

**Files:**
- Create: `Sources/RemoraApp/TerminalAIAssistantCoordinator.swift`
- Modify: `Sources/RemoraApp/WorkspaceViewModel.swift`
- Test: `Tests/RemoraAppTests/TerminalAIAssistantCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

Cover disabled-state gating, session history isolation, context assembly, and smart-assist detection.

- [ ] **Step 2: Implement coordinator state machine**

Support prompt submission, recent-output quick actions, smart assist, and per-session message history.

- [ ] **Step 3: Attach coordinator to each terminal pane model**

Update `WorkspaceViewModel.swift` so every pane owns its own assistant coordinator.

- [ ] **Step 4: Run targeted tests**

Run: `swift test --filter TerminalAIAssistantCoordinatorTests`

- [ ] **Step 5: Commit**

Commit coordinator work and tests.

### Task 5: Expose safe assistant actions in terminal runtime

**Files:**
- Modify: `Sources/RemoraApp/TerminalRuntime.swift`
- Test: `Tests/RemoraAppTests/TerminalRuntimeTests.swift`

- [ ] **Step 1: Write failing runtime tests**

Add tests for inserting command text without execution and executing a confirmed assistant command through the runtime.

- [ ] **Step 2: Implement runtime helper APIs**

Expose explicit public helpers for inserting assistant-generated text and sending confirmed command input.

- [ ] **Step 3: Run targeted tests**

Run: `swift test --filter TerminalRuntimeTests`

- [ ] **Step 4: Commit**

Commit runtime integration hooks.

## Chunk 4: Settings UI and terminal drawer UI

### Task 6: Add AI pane to settings

**Files:**
- Modify: `Sources/RemoraApp/RemoraSettingsSheet.swift`
- Modify: `Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `Tests/RemoraAppTests/RemoraUIAutomationTests.swift`

- [ ] **Step 1: Add AI settings pane navigation**

Insert a new `AI` pane in the settings tab list.

- [ ] **Step 2: Build AI settings cards**

Add the availability, provider, connection, model, and assistant behavior sections using existing settings-card patterns.

- [ ] **Step 3: Localize all new copy**

Update both localization files for every new visible/help string.

- [ ] **Step 4: Add UI automation coverage**

Add or update settings-focused UI tests to verify the AI pane opens and saves representative values.

- [ ] **Step 5: Run targeted tests**

Run: `swift test --filter RemoraUIAutomationTests`

- [ ] **Step 6: Commit**

Commit settings UI and localization changes.

### Task 7: Add assistant drawer to terminal panes

**Files:**
- Create: `Sources/RemoraApp/TerminalAIAssistantView.swift`
- Modify: `Sources/RemoraApp/TerminalPaneView.swift`
- Modify: `Sources/RemoraApp/VisualStyle.swift`
- Modify: `Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `Tests/RemoraAppTests/RemoraUIAutomationTests.swift`

- [ ] **Step 1: Add terminal header AI affordance**

Add a small AI toggle button that matches the existing terminal-header action style.

- [ ] **Step 2: Build drawer UI**

Render the assistant timeline, quick actions, prompt composer, command cards, and warnings.

- [ ] **Step 3: Add smart assist banner**

Show a dismissible inline hint when coordinator heuristics detect an obvious command failure.

- [ ] **Step 4: Localize new UI strings**

Update both localization files again for drawer and action strings.

- [ ] **Step 5: Add/update UI tests**

Cover drawer toggling, quick actions, and command insertion or execution affordances.

- [ ] **Step 6: Run targeted tests**

Run: `swift test --filter RemoraUIAutomationTests`

- [ ] **Step 7: Commit**

Commit terminal drawer UI and tests.

## Chunk 5: Full verification and polish

### Task 8: Verify end-to-end behavior and clean up

**Files:**
- Modify: any files required by verification fixes

- [ ] **Step 1: Run repo-wide diagnostics via compiler/test cycle**

Run: `swift build`

- [ ] **Step 2: Run full test suite**

Run: `swift test`

Expected: all AI-related tests pass; note the pre-existing `LocalShellClientTests.localShellUsesUTF8LocaleForChineseInputAndFilenames` failure if it remains unchanged.

- [ ] **Step 3: Verify light and dark appearance**

Launch the app and inspect the AI settings pane and terminal drawer in both appearances.

- [ ] **Step 4: Fix verification issues**

Resolve any build/test/UI regressions caused by the new feature.

- [ ] **Step 5: Final commit(s)**

Split remaining polish into atomic commits by concern.
