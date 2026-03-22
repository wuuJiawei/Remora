# Changelog

All notable changes to this project will be documented in this file.

This project generally follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html), with pre-release style suffixes where needed during active iteration.

## [Unreleased]

## [v0.14.0] - 2026-03-22

### Added

- Added a unified file-backed preferences layer so Remora can persist app settings, AI settings, and other durable defaults under `~/.config/remora`.
- Added a shared config-path and JSON persistence foundation for Remora's local-first storage model, including dedicated settings, connections, credentials, and keyboard-shortcuts files.

### Changed

- Moved saved SSH connections, stored credentials, app preferences, AI configuration, language/appearance settings, and keyboard shortcuts out of Keychain / `UserDefaults` / legacy dotfiles and into JSON files under `~/.config/remora`.
- Updated in-app storage wording, README copy, and wiki docs to reflect the new config-file based persistence model and the current Terminal AI workflow.

### Fixed

- Settings consumers across the app now read and write the same shared preferences document more consistently, reducing drift between settings screens and live workspace behavior.

## [v0.13.0] - 2026-03-20

### Added

- Added a complete Terminal AI workflow inside terminal panes, including provider-first configuration, custom endpoint support, model presets, per-pane assistant drawers, and localized AI settings.
- Added provider integrations for OpenAI-compatible and Claude-compatible APIs, plus built-in presets for OpenAI, Anthropic, OpenRouter, DeepSeek, Qwen / DashScope, and Ollama.
- Added a native AI composer with IME-safe keyboard handling, queued prompt submission while responses are still running, and opencode-inspired assistant interaction polish.
- Added hidden summary-turn based context compaction so longer AI conversations can retain earlier context without sending the full raw history every time.

### Changed

- Refined the Terminal AI drawer layout, quick actions, queue strip, streaming/thinking presentation, jump-to-latest behavior, and confirmation flow for running suggested commands.
- Updated built-in model presets to newer mainstream model IDs across OpenAI, Claude, Qwen, and DeepSeek providers.
- Simplified the Terminal AI drawer header by removing the unreliable working-directory display and restoring the quick-action row to a more usable size and alignment.

### Fixed

- Local shell sessions now reliably bootstrap into a UTF-8 locale, fixing `locale charmap`, Chinese filenames, and Chinese command echo behavior in automated tests and interactive sessions.
- Terminal AI command execution was restored to direct non-interfering Run behavior after removing automatic terminal interruption before command dispatch.

## [v0.12.0] - 2026-03-19

### Added

- Added a remote live log viewer with follow mode, adjustable line count, and inline refresh controls for SSH file-manager workflows.
- Added quick download buttons directly inside the remote editor and live-view popups so opened files can be downloaded without returning to the file list.
- Added a dedicated parent-directory navigation button to the file-manager toolbar, separate from history back/forward.
- Added a dedicated visual permissions editor for remote files with owner/group/public rwx toggles, synchronized octal mode editing, editable owner/group fields, and optional recursive apply.

### Changed

- Terminal and file-manager bottom panels now support accordion-style visibility rules, while still allowing both panels to stay open together.
- Collapsed terminal state now docks directly under the tab bar and lets the file-manager panel expand to fill the remaining space.
- The terminal collapse control now lives in the SSH header row and supports full-row clicking instead of only the chevron hit target.
- FTP table headers now sort when clicking anywhere in the full header cell instead of requiring precise label clicks.
- Quick-path and file-manager toolbar controls now use a more consistent icon-button treatment.

### Fixed

- FTP refresh now reconnects the SSH session when the underlying connection has timed out or disconnected, instead of requiring users to switch back to the terminal reconnect button first.
- Remote editor and live-view popups now expose copy-path/download actions more consistently, reducing extra navigation for common file operations.
- The new permissions editor now ships with complete Chinese localization and follows the app's localization rules.

## [v0.11.1] - 2026-03-14

### Fixed

- SSH terminal sessions now always provide a valid `TERM` value to the spawned `ssh` process, so TUI commands like `top` and `htop` no longer fail on hosts that require terminal type detection.

## [v0.11.0] - 2026-03-13

### Changed

- Replaced the custom terminal parser, buffer, renderer, and input stack with a SwiftTerm-based terminal integration.
- `Remora.xcodeproj` now matches the SwiftTerm migration and resolves Swift package dependencies correctly in Xcode.

### Fixed

- Terminal panes now keep a consistent 10pt breathing space around the terminal content instead of rendering flush to the pane border.
- Xcode builds no longer reference deleted custom terminal source files after the terminal-stack migration.

## [v0.10.7] - 2026-03-13

### Added

- SSH sidebar now supports drag-and-drop ordering for top-level groups and SSH connections, including moving connections between groups and the ungrouped flat list.
- New SSH connections can now remain ungrouped instead of being forced into a named group.
- Session tab context menus now include a direct SSH reconnect action.
- Project site homepage now includes direct download buttons for Apple Silicon and Intel release builds.

### Changed

- Deleting an SSH group can now either delete its contained connections or move them back to the ungrouped list.
- Split session panes now preserve the original terminal content, create a live connected pane from the current session context, and allow closing the extra pane directly.

### Fixed

- SSH sidebar quick-delete and context-menu delete actions now require confirmation before removing a connection.
- Local shell sessions now force a UTF-8 locale so Chinese filenames and command input round-trip correctly.

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
