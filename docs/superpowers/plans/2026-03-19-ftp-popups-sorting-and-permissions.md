# FTP Popups, Sorting, and Permissions Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement three approved FTP/file-manager improvements, each with its own test cycle and its own git commit.

**Architecture:** Keep each requirement isolated: popup download actions in the popup sheets, sorting hit-area changes in `FileManagerPanelView.swift`, and permissions editing in a dedicated permissions-focused flow layered on top of existing remote attributes APIs. Reuse shared helpers where appropriate, but do not bundle unrelated functionality into the same commit.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, RemoraApp / RemoraCore SFTP models and view models

---

## Chunk 1: Popup download buttons

### Task 1: Add quick download buttons to the remote editor and live viewer

**Files:**
- Modify: `Sources/RemoraApp/RemoteTextEditorSheet.swift`
- Modify: `Sources/RemoraApp/RemoteLogViewerSheet.swift`
- Modify: `Tests/RemoraAppTests/RemoraUIAutomationTests.swift` (or popup-focused tests if already present)

- [ ] **Step 1: Write failing regression coverage**
- [ ] **Step 2: Run the focused tests to verify failure**
- [ ] **Step 3: Add download icon buttons and queue-download behavior**
- [ ] **Step 4: Run focused tests to verify pass**
- [ ] **Step 5: Commit only requirement 1 files**

## Chunk 2: Full-header sorting hit area

### Task 2: Make sortable FTP headers clickable across the full header cell

**Files:**
- Modify: `Sources/RemoraApp/FileManagerPanelView.swift`
- Modify: `Tests/RemoraAppTests/RemoraUIAutomationTests.swift` and/or focused sorting tests

- [ ] **Step 1: Write failing regression coverage for header hit area**
- [ ] **Step 2: Run the focused tests to verify failure**
- [ ] **Step 3: Expand header click targets without changing sort semantics**
- [ ] **Step 4: Run focused tests to verify pass**
- [ ] **Step 5: Commit only requirement 2 files**

## Chunk 3: Dedicated permissions editor flow

### Task 3: Add a visual Edit Permissions dialog and separate menu entry

**Files:**
- Modify: `Sources/RemoraApp/FileManagerPanelView.swift`
- Modify: `Sources/RemoraApp/RemoteFilePropertiesSheet.swift` (only if still needed for shared presentation patterns)
- Modify/Create: `Sources/RemoraApp/RemoteFilePropertiesViewModel.swift` and/or a new dedicated permissions editor view model
- Create: `Sources/RemoraApp/RemotePermissionsEditorSheet.swift` (recommended)
- Modify: `Tests/RemoraAppTests/*` for permissions parsing/sync and UI flow coverage

- [ ] **Step 1: Write failing tests for permission-mode synchronization and save flow**
- [ ] **Step 2: Run the focused tests to verify failure**
- [ ] **Step 3: Implement the separate Edit Permissions flow with rwx toggles, numeric mode sync, owner/group fields, and recursive apply**
- [ ] **Step 4: Run focused tests to verify pass**
- [ ] **Step 5: Commit only requirement 3 files**

## Chunk 4: Final verification

### Task 4: Verify the combined result after all three commits

**Files:**
- Verify all modified files from chunks 1-3

- [ ] **Step 1: Run `lsp_diagnostics` on all modified Swift files**
- [ ] **Step 2: Run focused tests for all three requirements**
- [ ] **Step 3: Run `swift build`**
- [ ] **Step 4: Run `swift test` and record any unchanged baseline failures only**
