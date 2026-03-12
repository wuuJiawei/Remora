<p align="center">
  <img src="./logo.png" alt="Remora logo" width="140" />
</p>

<h1 align="center">Remora</h1>

<p align="center"><strong>Hitch a ride to any shell.</strong></p>

<p align="center">
  A native macOS SSH + SFTP workspace built with SwiftUI and a custom high-performance terminal engine.
</p>

> [!WARNING]
> Remora is still a WIP, early-stage project. Expect rough edges, missing workflows, and behavioral changes between releases. If you hit a bug, regression, or confusing UX, please open an issue as early as possible: <https://github.com/wuuJiawei/Remora/issues>

<p align="center">
  <a href="./README.md">简体中文</a> •
  <a href="#features">Features</a> •
  <a href="#screenshots">Screenshots</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#faq">FAQ</a> •
  <a href="#project-structure">Project Structure</a> •
  <a href="#architecture">Architecture</a> •
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
- Secure: Local-first credential strategy with saved passwords stored only in macOS Keychain, SSH host key verification via `StrictHostKeyChecking=ask`, and explicit opt-in before any plaintext password export or copy.
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
- Xcode 15.4+

### Run from Source

```bash
swift build
swift run RemoraApp
```

If you prefer Xcode, open `Remora.xcodeproj` and run the `Remora` scheme.

### Package Locally

Local packaging and GitHub Actions use the same command:

```bash
./scripts/package_macos.sh --arch "$(uname -m)" --version 0.0.0-local --build-number 1
```

The packaged app is written to `dist/`, for example:

```bash
dist/Remora-0.0.0-local-macos-arm64.zip
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

## FAQ

### Q: macOS says "`Remora.app` is damaged and can't be opened". What should I do?

A: First confirm the app came from a trusted source (for example, GitHub Releases) and was fully unzipped.  
Then remove the quarantine attribute in Terminal (replace with your local path):

```bash
xattr -dr com.apple.quarantine /path/to/Remora.app
```

### Q: It still won't open after removing quarantine. What next?

A: Allow it once from macOS Settings:

1. Open `System Settings` -> `Privacy & Security`.
2. Find the blocked `Remora.app` notice in the Security section.
3. Click `Open Anyway` and confirm.

## Project Structure

- `Sources/RemoraCore`: SSH/SFTP/session/host/security/core models.
- `Sources/RemoraTerminal`: parser, buffer, renderer, terminal input/view.
- `Sources/RemoraApp`: SwiftUI app, workspace UI, settings, file manager.
- `Sources/TerminalStressTool`: terminal throughput/stress utility.
- `Tests/*`: core, terminal, and app tests.
- `docs/`: checklists, screenshots, and operational notes.

## Architecture

See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the module diagram and the
high-level flow between `RemoraCore`, `RemoraTerminal`, and `RemoraApp`.

## Contributing

Contributions are welcome.

- Please read [`CONTRIBUTING.md`](./CONTRIBUTING.md) before opening a PR.
- Please follow [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md) in community spaces.
- For bugs/feature requests, use [GitHub Issues](https://github.com/wuuJiawei/Remora/issues).

## Community

- GitHub: [wuuJiawei/Remora](https://github.com/wuuJiawei/Remora)
- Issues: [Report a bug / request a feature](https://github.com/wuuJiawei/Remora/issues)
- Support: [`SUPPORT.md`](./SUPPORT.md)
- X (updates): [@1Javeys](https://x.com/1Javeys)

## Security

Please read [`SECURITY.md`](./SECURITY.md) for responsible disclosure.

## Open Source Checklist

See [`docs/OPEN_SOURCE_CHECKLIST.md`](./docs/OPEN_SOURCE_CHECKLIST.md) for the pre-public checklist.

## Changelog

See [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

## License

Licensed under the MIT License. See [`LICENSE`](./LICENSE).
