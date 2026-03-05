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
  <a href="#community">Community</a> •
  <a href="#contributing">Contributing</a>
</p>

---

## Why Remora?

Remora focuses on a practical split:

- Native macOS UX for connection/session management.
- A custom terminal core for VT rendering/input performance.
- SSH + SFTP workflows in one place.

## Features

- Fantastic: Local-first SSH + SFTP workspace, ANSI/VT support for modern TUIs, xterm-style selection, quick commands/quick paths, drag-and-drop transfers.
- Beautiful: Native macOS UI with clean split layout, light/dark/system themes, and distraction-free terminal focus.
- Fast: Swift 6 native architecture with a custom terminal engine (buffer + parser + renderer), built to outperform typical Electron-based terminal apps under heavy TUI/scroll workloads.
- Simple: Lightweight app with a 99% Swift-native stack, keyboard-driven workflows, and practical defaults that work out of the box.

### What You Can Do Today

- Run local shell and SSH sessions with multi-tab/pane workspace.
- Manage hosts with groups, search, favorites, and quick connect.
- Use SFTP file manager for create/rename/move/delete/copy/paste/upload/download.
- Drag files onto directories or current path with visual upload target hints.
- Get immediate operation feedback via toasts and retry failed transfer tasks.
- Sync terminal directory with file manager navigation when needed.
- Configure language, appearance, shortcuts, and metrics in settings.

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

## Community

- GitHub: [wuuJiawei/Remora](https://github.com/wuuJiawei/Remora)
- Issues: [Report a bug / request a feature](https://github.com/wuuJiawei/Remora/issues)
- X (updates): [@1Javeys](https://x.com/1Javeys)

## Security

Please read [`SECURITY.md`](./SECURITY.md) for responsible disclosure.

## Open Source Checklist

See [`docs/OPEN_SOURCE_CHECKLIST.md`](./docs/OPEN_SOURCE_CHECKLIST.md) for the pre-public checklist.

## Changelog

See [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

## License

Licensed under the Apache License 2.0. See [`LICENSE`](./LICENSE).
