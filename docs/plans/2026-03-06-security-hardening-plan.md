# Security Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Harden credential handling, export/clipboard behavior, SSH password auth, and download memory usage without breaking normal SSH/SFTP workflows.

**Architecture:** Store secrets in Keychain with actor-local memory caching, make all risky password exposure paths explicit opt-in, remove output-sniffing password autofill, and add a direct-to-file transfer path for downloads. Keep the UI native and minimize behavioral drift by layering new warnings and options onto the existing host editor and export flow.

**Tech Stack:** Swift 6, SwiftUI, Security.framework, Foundation, XCTest

---

### Task 1: Planning Docs

**Files:**
- Create: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/docs/plans/2026-03-06-security-hardening-design.md`
- Create: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/docs/plans/2026-03-06-security-hardening-plan.md`

**Step 1: Write the docs**

- Capture scope, constraints, testing plan, and commit plan.

**Step 2: Commit**

```bash
git add docs/plans/2026-03-06-security-hardening-design.md docs/plans/2026-03-06-security-hardening-plan.md
git commit -m "docs: add security hardening plan"
```

### Task 2: Keychain Credential Store And Save Password Warning

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraCore/Security/CredentialStore.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/ContentView.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraCoreTests/CredentialStoreTests.swift`

**Step 1: Write the failing tests**

- Cover Keychain-backed set/get/remove behavior and cache-after-read behavior.

**Step 2: Run test to verify it fails**

Run: `swift test --filter CredentialStoreTests`

**Step 3: Write minimal implementation**

- Replace file persistence with Keychain reads/writes.
- Keep actor memory cache.
- Add host editor warning state and save-to-Keychain wording.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter CredentialStoreTests`

**Step 5: Commit**

```bash
git add Sources/RemoraCore/Security/CredentialStore.swift Sources/RemoraApp/ContentView.swift Sources/RemoraApp/Resources/en.lproj/Localizable.strings Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings Tests/RemoraCoreTests/CredentialStoreTests.swift
git commit -m "feat: move saved credentials to keychain"
```

### Task 3: Export, Clipboard, And Command Safety

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/HostConnectionExporter.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/HostConnectionClipboardBuilder.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/ContentView.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/Resources/en.lproj/Localizable.strings`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/HostConnectionExporterTests.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/HostConnectionClipboardBuilderTests.swift`

**Step 1: Write the failing tests**

- Assert exports omit passwords by default and include them only when requested.
- Assert clipboard text never includes a password.
- Assert copied SSH command is shell-safe.

**Step 2: Run test to verify it fails**

Run: `swift test --filter 'HostConnection(Exporter|ClipboardBuilder)Tests'`

**Step 3: Write minimal implementation**

- Add explicit export option and warning flow.
- Remove password from copied connection info.
- Quote the copied SSH command safely.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter 'HostConnection(Exporter|ClipboardBuilder)Tests'`

**Step 5: Commit**

```bash
git add Sources/RemoraApp/HostConnectionExporter.swift Sources/RemoraApp/HostConnectionClipboardBuilder.swift Sources/RemoraApp/ContentView.swift Sources/RemoraApp/Resources/en.lproj/Localizable.strings Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings Tests/RemoraAppTests/HostConnectionExporterTests.swift Tests/RemoraAppTests/HostConnectionClipboardBuilderTests.swift
git commit -m "fix: harden export and clipboard password handling"
```

### Task 4: SSH Password Transport Hardening

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraCore/SSH/SystemSSHClient.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraCore/SFTP/SystemSFTPClient.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraCoreTests/SystemSSHClientTests.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraCoreTests/SystemSFTPClientTests.swift`

**Step 1: Write the failing tests**

- Assert password auth launch config uses explicit helper transport instead of output sniffing.
- Assert batch quoting escapes newline/carriage-return edge cases.

**Step 2: Run test to verify it fails**

Run: `swift test --filter '(SystemSSHClientTests|SystemSFTPClientTests)'`

**Step 3: Write minimal implementation**

- Remove `password:` output matching.
- Introduce password launch helper logic for SSH shell sessions.
- Harden batch argument escaping.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter '(SystemSSHClientTests|SystemSFTPClientTests)'`

**Step 5: Commit**

```bash
git add Sources/RemoraCore/SSH/SystemSSHClient.swift Sources/RemoraCore/SFTP/SystemSFTPClient.swift Tests/RemoraCoreTests/SystemSSHClientTests.swift Tests/RemoraCoreTests/SystemSFTPClientTests.swift
git commit -m "fix: harden ssh password transport"
```

### Task 5: Streaming Download Path

**Files:**
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraCore/Protocols/SFTPProtocols.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraCore/SFTP/SystemSFTPClient.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraCore/SFTP/MockSFTPClient.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraCore/SFTP/DisconnectedSFTPClient.swift`
- Modify: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Sources/RemoraApp/FileTransferViewModel.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraCoreTests/SystemSFTPClientTests.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraCoreTests/MockSFTPClientTests.swift`
- Test: `/Users/wuu/Projects/indie-hacker/lighting-tech.io/Remora/Tests/RemoraAppTests/FileTransferViewModelTests.swift`

**Step 1: Write the failing tests**

- Assert downloads can write directly to a local URL.
- Assert file transfer download path uses direct file output.

**Step 2: Run test to verify it fails**

Run: `swift test --filter '(SystemSFTPClientTests|MockSFTPClientTests|FileTransferViewModelTests)'`

**Step 3: Write minimal implementation**

- Add direct-to-file download API.
- Use direct SFTP/SSH transfer into destination files.
- Keep existing `Data`-returning API for text/document paths.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter '(SystemSFTPClientTests|MockSFTPClientTests|FileTransferViewModelTests)'`

**Step 5: Commit**

```bash
git add Sources/RemoraCore/Protocols/SFTPProtocols.swift Sources/RemoraCore/SFTP/SystemSFTPClient.swift Sources/RemoraCore/SFTP/MockSFTPClient.swift Sources/RemoraCore/SFTP/DisconnectedSFTPClient.swift Sources/RemoraApp/FileTransferViewModel.swift Tests/RemoraCoreTests/SystemSFTPClientTests.swift Tests/RemoraCoreTests/MockSFTPClientTests.swift Tests/RemoraAppTests/FileTransferViewModelTests.swift
git commit -m "feat: stream remote downloads to disk"
```

### Task 6: Final Verification

**Files:**
- Verify only

**Step 1: Run focused verification**

Run:

```bash
swift test --filter CredentialStoreTests
swift test --filter 'HostConnection(Exporter|ClipboardBuilder)Tests'
swift test --filter '(SystemSSHClientTests|SystemSFTPClientTests|MockSFTPClientTests|FileTransferViewModelTests)'
```

**Step 2: Run broader regression sweep**

Run:

```bash
swift test --filter '(HostCatalogPersistenceStoreTests|HostConnectionImporterTests|RemoteFilePropertiesViewModelTests)'
```

**Step 3: Summarize evidence**

- Report exact commands run, exit codes, and any skipped coverage.
