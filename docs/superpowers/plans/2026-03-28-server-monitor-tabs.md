# Server Monitor Tabs Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing server status popup into a 3-tab native SwiftUI monitoring dashboard with system info, network monitoring, and process monitoring, all supporting live refresh and sortable tables.

**Architecture:** Keep `ServerMetricsCenter` as the polling source of truth, extend its parsed snapshot to carry network socket rows and process rows, and let `ServerMetricsPanel` become a tabbed SwiftUI container. Use native `TabView` + `Table` on macOS, keep all user-facing strings localized, and preserve the existing metrics dashboard as the first tab.

**Tech Stack:** SwiftUI, AppKit window hosting, Swift Testing, remote Linux shell sampling via existing `SystemSFTPClient` command execution.

---

## Chunk 1: Expand the metrics domain model and parsing

### Task 1: Add snapshot row models for network and process monitoring

**Files:**
- Modify: `Sources/RemoraApp/ServerMetricsCenter.swift`
- Test: `Tests/RemoraAppTests/ServerMetricsParsingTests.swift`

- [ ] **Step 1: Write the failing parsing tests**
  - Add test coverage for parsed network listener rows (pid, process name, listen address, port, unique remote IP count, connection count, sent bytes, received bytes).
  - Add test coverage for parsed process rows (pid, user, memory bytes, cpu percent, command summary, executable path).

- [ ] **Step 2: Run the parsing tests to verify they fail**

Run: `swift test --filter ServerMetricsParsingTests`
Expected: FAIL because the snapshot model and parser do not yet expose the new rows.

- [ ] **Step 3: Implement the minimal parsing changes**
  - Add new sendable row structs under the existing metrics snapshot types.
  - Extend `ServerResourceMetricsSnapshot` with `networkConnections` and `processDetails` arrays.
  - Expand the probe shell script to emit stable `net_<n>=...` and `ps_<n>=...` records.
  - Parse the records without regressing existing fields.

- [ ] **Step 4: Run the parsing tests to verify they pass**

Run: `swift test --filter ServerMetricsParsingTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RemoraApp/ServerMetricsCenter.swift Tests/RemoraAppTests/ServerMetricsParsingTests.swift
git commit -m "feat: expand server metrics snapshot rows"
```

## Chunk 2: Add sortable tabbed monitoring UI

### Task 2: Convert the popup body into a native 3-tab panel

**Files:**
- Modify: `Sources/RemoraApp/ServerStatusWindow.swift`
- Modify: `Sources/RemoraApp/ServerMetricsPanel.swift`
- Test: `Tests/RemoraAppTests/ServerStatusWindowTests.swift`
- Test: `Tests/RemoraAppTests/ServerMetricsPanelTests.swift`

- [ ] **Step 1: Write the failing UI tests**
  - Add a window test proving the popup grows to a table-friendly width.
  - Add panel rendering assertions for the tab bar and wider layout.

- [ ] **Step 2: Run the targeted UI tests to verify they fail**

Run: `swift test --filter ServerStatusWindowTests && swift test --filter ServerMetricsPanelTests`
Expected: FAIL because the current panel is single-tab and narrower.

- [ ] **Step 3: Implement the minimal tab container**
  - Keep the current dashboard content intact as tab 1 named `系统信息监控` / `System Information Monitoring`.
  - Use native `TabView` and preserve the existing placeholder/error/loading states.
  - Increase the popup width/min width only as much as needed for the new tables.

- [ ] **Step 4: Run the targeted UI tests to verify they pass**

Run: `swift test --filter ServerStatusWindowTests && swift test --filter ServerMetricsPanelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RemoraApp/ServerStatusWindow.swift Sources/RemoraApp/ServerMetricsPanel.swift Tests/RemoraAppTests/ServerStatusWindowTests.swift Tests/RemoraAppTests/ServerMetricsPanelTests.swift
git commit -m "feat: add tabbed server monitoring panel"
```

### Task 3: Add a sortable native network monitoring table

**Files:**
- Modify: `Sources/RemoraApp/ServerMetricsPanel.swift`
- Test: `Tests/RemoraAppTests/ServerMetricsPanelTests.swift`

- [ ] **Step 1: Write the failing network-table tests**
  - Add behavior coverage for default sort order and explicit sorting helpers used by the network tab.
  - Verify sample data renders in the tab without breaking light/dark rendering.

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `swift test --filter ServerMetricsPanelTests`
Expected: FAIL because the network tab and sorting logic do not exist.

- [ ] **Step 3: Implement the minimal network tab**
  - Use native `Table` columns for PID, process name, listen IP, port, remote IP count, connection count, upload, and download.
  - Back sorting with stable comparators and state local to the view.
  - Show a native empty state when no rows are available.

- [ ] **Step 4: Run the targeted tests to verify they pass**

Run: `swift test --filter ServerMetricsPanelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RemoraApp/ServerMetricsPanel.swift Tests/RemoraAppTests/ServerMetricsPanelTests.swift
git commit -m "feat: add network monitoring tab"
```

### Task 4: Add a sortable native process monitoring table

**Files:**
- Modify: `Sources/RemoraApp/ServerMetricsPanel.swift`
- Test: `Tests/RemoraAppTests/ServerMetricsPanelTests.swift`

- [ ] **Step 1: Write the failing process-table tests**
  - Add behavior coverage for the process sort helpers and row formatting.
  - Verify process data renders in the tab and stays readable in both appearances.

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `swift test --filter ServerMetricsPanelTests`
Expected: FAIL because the process tab and sorting logic do not exist.

- [ ] **Step 3: Implement the minimal process tab**
  - Use native `Table` columns for PID, user, memory, CPU, command, and location.
  - Reuse consistent formatting helpers and keep the table within the native macOS look.
  - Show a native empty state when no rows are available.

- [ ] **Step 4: Run the targeted tests to verify they pass**

Run: `swift test --filter ServerMetricsPanelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RemoraApp/ServerMetricsPanel.swift Tests/RemoraAppTests/ServerMetricsPanelTests.swift
git commit -m "feat: add process monitoring tab"
```

## Chunk 3: Localization and full verification

### Task 5: Localize new copy and run the full verification pass

**Files:**
- Modify: `Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `Tests/RemoraAppTests/L10nTests.swift`

- [ ] **Step 1: Write/update failing localization tests**
  - Add assertions for all new tab titles, table headers, and empty-state copy.

- [ ] **Step 2: Run the localization tests to verify they fail**

Run: `swift test --filter L10nTests`
Expected: FAIL because the new keys do not exist yet.

- [ ] **Step 3: Implement the minimal localization updates**
  - Add matching keys to both English and Simplified Chinese string tables.
  - Ensure all new UI copy uses `tr(...)`/`L10n.tr(...)`.

- [ ] **Step 4: Run the focused and full verification suite**

Run: `swift test --filter ServerMetricsParsingTests && swift test --filter ServerMetricsPanelTests && swift test --filter ServerStatusWindowTests && swift test --filter L10nTests && swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RemoraApp/Resources/en.lproj/Localizable.strings Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings Tests/RemoraAppTests/L10nTests.swift
git commit -m "feat: localize monitoring tabs"
```
