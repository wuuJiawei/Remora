# Changelog

All notable changes to this project will be documented in this file.

This project generally follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html), with pre-release style suffixes where needed during active iteration.

## [Unreleased]

## [v0.10.6] - 2026-03-12

### Fixed

- macOS release bundles now declare the application icon through the standard Xcode asset catalog pipeline, so Finder and Dock both display the same icon after users unzip the packaged app.
- Removed the runtime-only Dock icon override path, eliminating the mismatch where packaged apps showed a generic Finder icon until launch.

## [v0.10.5] - 2026-03-12

### Changed

- macOS packaging now uses the native Xcode app archive flow locally and in GitHub Actions via `scripts/package_macos.sh`.
- The app now loads localized resources from the standard app bundle at runtime instead of relying on SwiftPM resource-bundle path fallbacks.
- README and installation docs now point to the Xcode project and the shared packaging script as the primary release workflow.

## [v0.10.4] - 2026-03-08

### Added

- Shell cursor navigation now supports direct mouse positioning on the active prompt line.
- Terminal shell editing now hands off keyboard input correctly when TUI apps take over the screen.

### Changed

- Terminal input now feels more immediate by flushing active-pane output without the extra frame of delay.
- Terminal caret rendering now blinks, aligns with glyph metrics, and stays in sync with IME placement.
- Terminal buffer reflow behaves more reliably after width changes.
- License switched from Apache-2.0 to MIT.

### Fixed

- Left/right arrow movement, Command-based cursor jumps, and prompt-line mouse clicks now land on the expected shell position.
- Terminal caret hit-testing no longer requires repeated clicks to settle onto the intended column.
- Terminal cell width uses precise glyph measurements, removing the visible gap between prompt text and caret.
- Accessibility transcript snapshots now strip shell editing escape sequences instead of exposing raw ANSI bytes.
- Packaged app bundles keep SwiftPM resources under `Contents/Resources`, avoiding launch-time `Bundle.module` failures.

## [v0.9.1-open-source-readiness] - 2026-03-04

### Added

- Open-source docs set:
  - `CONTRIBUTING.md`
  - `SECURITY.md`
  - `docs/OPEN_SOURCE_CHECKLIST.md`
- Apache-2.0 `LICENSE`.
- README screenshots for SSH workspace, terminal TUI, and file manager workflow.
- File manager operation toasts for user feedback (copy/cut/delete/paste/upload/download/move/rename/create/retry).
- FTP/SFTP drag-and-drop enhancements:
  - upload destination routing (directory target vs current directory fallback)
  - destination hint overlay
  - stronger directory drop target affordances (icon + subtle scale animation).

### Changed

- Reworked `README.md` for public open-source launch with a full feature matrix and clearer quick start/testing docs.
- Reorganized planning docs into `docs/` and removed legacy OpenSpec artifacts from repository root.

## [v0.9.0-altscreen-start]

- Baseline milestone tag for alternate-screen and TUI compatibility work.

## [v0.8.0-ssh-reconnect-fixes-start]

- Baseline milestone tag for SSH reconnect stability work.

## [v0.8.0-pre-major-changes]

- Baseline milestone tag before major terminal/file-manager feature wave.
