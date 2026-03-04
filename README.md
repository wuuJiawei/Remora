<p align="center">
  <img src="./logo.png" alt="Remora logo" width="140" />
</p>

<h1 align="center">Remora</h1>

<p align="center"><strong>Hitch a ride to any shell.</strong></p>

<p align="center">
  A native macOS SSH + SFTP workspace built with SwiftUI and a custom high-performance terminal engine.
</p>

<p align="center">
  <a href="./README_ZH.md">简体中文</a> •
  <a href="#features">Features</a> •
  <a href="#screenshots">Screenshots</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#project-structure">Project Structure</a> •
  <a href="#testing">Testing</a> •
  <a href="#contributing">Contributing</a>
</p>

---

## Why Remora?

Remora focuses on a practical split:

- Native macOS UX for connection/session management.
- A custom terminal core for VT rendering/input performance.
- SSH + SFTP workflows in one place.

## Features

### Terminal & Session

- Native terminal view (`NSView`) hosted inside SwiftUI.
- ANSI/VT support for common modern TUIs.
- Selection experience inspired by xterm-style behavior:
  - Drag selection, double-click word selection.
  - Triple-click logical line selection.
  - Option/Alt column (rectangular) selection.
  - Selection anchored to buffer space (stable across scrolling).
- Local shell and SSH session support.
- Multi-session tabs and pane-based workspace layout.
- Reconnect entry point for SSH sessions.

### SSH Host Management

- Host catalog with groups, search, templates, favorites, recent connections.
- Quick connect and quick actions from sidebar/top-level workflow.
- Host auth methods (agent/password/private key) with secure storage paths.
- Host key trust prompt flow.
- Per-host quick commands.

### SFTP / File Manager

- Local + remote file browser panel.
- Remote operations: create file/folder, rename, move, delete, copy/cut/paste, download/upload.
- Transfer queue with progress/state and retry support.
- Drag-and-drop upload:
  - Drop on directory row -> upload into that directory.
  - Drop on file row or blank list area -> upload into current directory.
  - Visual destination hint (`Drop to upload to <path>`) and drop-target highlight.
- File manager operation toasts for immediate feedback (copy/cut/delete/paste/upload/download/etc.).
- Optional terminal-directory sync with file manager navigation.
- Per-host quick paths for FTP/SFTP workflows.

### App Experience

- Simplified Chinese + English localization.
- Light/Dark/System appearance support.
- Customizable app keyboard shortcuts (with conflict detection).
- Settings UI for language, appearance, file manager path, metrics sampling, and shortcuts.
- Built-in project/about links and issue entry points.
- Server metrics/status panel for connected SSH hosts.

## Screenshots

### SSH Workspace

![Remora SSH workspace](./docs/screenshots/PixPin_2026-03-04_22-45-28.png)

### Terminal (TUI-friendly)

![Remora terminal TUI](./docs/screenshots/PixPin_2026-03-04_22-45-57.png)

### File Manager + Transfer Workflow

![Remora file manager](./docs/screenshots/PixPin_2026-03-04_22-45-44.png)

## Quick Start

### Requirements

- macOS 14+
- Xcode 15.4+ (or Swift 6 toolchain)

### Build & Run

```bash
swift build
swift run RemoraApp
```

Optional stress tool:

```bash
swift run terminal-stress
```

## Testing

Run core test suites:

```bash
swift test
```

Run UI automation (opt-in):

```bash
REMORA_RUN_UI_TESTS=1 swift test --filter RemoraUIAutomationTests
```

If `RemoraApp` binary path is custom:

```bash
REMORA_RUN_UI_TESTS=1 REMORA_APP_BINARY=/abs/path/to/RemoraApp swift test --filter RemoraUIAutomationTests
```

## Project Structure

- `Sources/RemoraCore`: SSH/SFTP/session/host/security/core models.
- `Sources/RemoraTerminal`: parser, buffer, renderer, terminal input/view.
- `Sources/RemoraApp`: SwiftUI app, workspace UI, settings, file manager.
- `Sources/TerminalStressTool`: terminal throughput/stress utility.
- `Tests/*`: core, terminal, and app tests.
- `docs/`: checklists, screenshots, and operational notes.

## Contributing

Contributions are welcome.

- Please read [`CONTRIBUTING.md`](./CONTRIBUTING.md) before opening a PR.
- For bugs/feature requests, use [GitHub Issues](https://github.com/wuuJiawei/Remora/issues).

## Security

Please read [`SECURITY.md`](./SECURITY.md) for responsible disclosure.

## Open Source Checklist

See [`docs/OPEN_SOURCE_CHECKLIST.md`](./docs/OPEN_SOURCE_CHECKLIST.md) for the pre-public checklist.

## Changelog

See [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

## License

Licensed under the Apache License 2.0. See [`LICENSE`](./LICENSE).
