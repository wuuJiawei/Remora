# Changelog

All notable changes to this project will be documented in this file.

This project generally follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html), with pre-release style suffixes where needed during active iteration.

## [Unreleased]

## [v0.14.2] - 2026-03-25

### English

#### Added

- Added adaptive SSH compatibility profiles that can automatically retry legacy SSH/SFTP servers with extra OpenSSH compatibility options and persist successful profiles for later connections. Fixed [#1](https://github.com/wuuJiawei/Remora/issues/1).
- Added remote shell integration installation before SSH startup so shell sessions can report working-directory changes through OSC 7 without relying on visible `pwd` probes.
- Added a dismissible Terminal AI smart-assist notification in the top-right corner of terminal panes, plus dedicated state coverage and UI automation checks for the new presentation.
- Added regression coverage for the sidebar help menu button so its menu opens correctly in both light and dark appearances without rendering the default popup indicator.

#### Changed

- Removed the host-editor password-save consent gate and simplified password persistence flow so saved passwords are managed directly through the new host-password storage path.
- Clarified that “Rename Session” only changes the current tab title, updated the sheet copy accordingly, and aligned the wording in both localized resources and UI tests.
- Removed the inline “Refreshing metrics…” label from the server-status window so metric refreshes stay visually stable while preserving the rest of the panel layout.
- Prevented the sidebar search field from auto-focusing at launch and hid the sidebar help menu’s default indicator so the sidebar feels cleaner on startup and in steady state.
- Renamed the active runtime SFTP state publisher to a more general connection-state name and extracted a runtime-connection sync coordinator to centralize runtime-driven service syncing.
- Updated the host-catalog bootstrap persistence flow so malformed persisted catalogs are never overwritten after a failed load, while pending in-memory snapshots still replay safely when appropriate.

#### Fixed

- Fixed PTY-backed system SSH shell sessions so resize operations propagate correctly to child processes and interactive full-screen tools redraw against the right terminal size.
- Fixed SSH/SFTP connection reuse decisions for password-auth fallback paths, allowing reuse when no stored password is available while still avoiding broken reuse paths for stored-password connections.
- Restored SSH terminal ↔ file-manager working-directory sync through shell integration, including sync preparation before SSH session startup and reuse of already-known directories when sync is enabled.
- Fixed terminal directory sync so enabling sync no longer sends redundant `pwd` probes, arbitrary commands do not trigger extra cwd probes, and typed `cd` commands propagate to the file manager directly.
- Fixed OSC 7 parsing and SSH startup handling so shell-integration cwd events survive prompt noise, preserve initial transcript banners, and still keep foreground TUI programs such as `top` usable.

#### Internal

- Stabilized terminal assistant and terminal runtime timing tests by replacing fixed sleeps with explicit waits and by relaxing timing windows where shell/runtime coordination is intentionally asynchronous.
- Updated app and UI automation coverage for shell-integration installation, smart-assist notifications, sidebar help menus, runtime sync behavior, and other regressions introduced during this release cycle.

#### Documentation

- Updated the README acknowledgements to thank the early users from the [2Libra](https://2libra.com/) and [V2EX](https://www.v2ex.com/) communities for their feedback and bug reports.

### 中文

#### 新增

- 新增自适应 SSH 兼容性配置：在连接老旧 SSH/SFTP 服务器失败时，可自动追加 OpenSSH 兼容参数重试，并持久化成功的兼容配置供后续连接复用。修复了 [#1](https://github.com/wuuJiawei/Remora/issues/1)。
- 新增 SSH 启动前的远端 shell integration 安装流程，使 shell 会话可以通过 OSC 7 上报工作目录变化，而不再依赖可见的 `pwd` 探测。
- 新增终端右上角可关闭的 Terminal AI 智能辅助通知，并补充了对应的状态测试与 UI 自动化覆盖。
- 新增侧边栏帮助菜单按钮的回归测试，确保它在浅色和深色外观下都能正常打开菜单，并且不会再渲染默认的下拉指示器。

#### 变更

- 移除了主机编辑器里的密码保存确认 gate，并简化了密码持久化流程，使已保存密码直接通过新的 host-password storage 路径管理。
- 明确了“重命名会话”只会修改当前标签标题，并同步更新了弹窗文案、本地化资源和对应 UI 测试。
- 移除了服务器状态窗口中的“正在刷新指标…”提示文案，让指标刷新过程保持更稳定的视觉布局，同时不影响其余内容显示。
- 禁止侧边栏搜索框在启动时自动获得焦点，并隐藏侧边栏帮助菜单的默认指示器，让侧边栏在启动和常态下都更干净。
- 将活动运行时的 SFTP 状态发布器重命名为更通用的连接状态命名，并提取出 runtime-connection sync coordinator 来统一运行时驱动的服务同步。
- 调整了 host catalog 的启动持久化流程：当已持久化目录加载失败且文件损坏时，不再覆盖原文件；在合适场景下，内存中的待保存快照仍可安全回放。

#### 修复

- 修复了基于 PTY 的系统 SSH shell 会话，使窗口大小变化能够正确传递给子进程，交互式全屏工具也能按正确终端尺寸重绘。
- 修复了密码认证回退路径下的 SSH/SFTP 连接复用决策：当没有已保存密码时允许复用，而对带已保存密码的连接继续避开有问题的复用路径。
- 通过 shell integration 恢复了 SSH 终端与文件管理器之间的工作目录同步，包括在 SSH 会话启动前完成同步准备，并在启用同步时复用已知目录。
- 修复了终端目录同步逻辑：启用同步时不再发送多余的 `pwd` 探测，任意命令也不会触发额外 cwd 探测，用户手动输入的 `cd` 会直接同步到文件管理器。
- 修复了 OSC 7 解析和 SSH 启动处理逻辑，使 shell integration 的 cwd 事件在带有提示符噪声时仍能正确识别，同时保留初始 transcript banner，并继续兼容 `top` 等前台 TUI 程序。

#### 内部

- 通过把固定 `sleep` 替换为显式等待，并放宽部分本就异步的 shell/runtime 协调时序窗口，提升了 terminal assistant 与 terminal runtime 相关测试的稳定性。
- 更新了 app 和 UI 自动化测试覆盖范围，覆盖 shell integration 安装、智能辅助通知、侧边栏帮助菜单、运行时同步行为以及本轮发布期间引入的其他回归场景。

#### 文档

- 更新了 README 致谢内容，感谢来自 [2Libra](https://2libra.com/) 和 [V2EX](https://www.v2ex.com/) 社区的早期用户所提供的反馈和问题报告。

## [v0.14.1] - 2026-03-22

### Fixed

- Regenerated `Remora.xcodeproj` from the project generator so the `RemoraCore` target now includes the new config-store sources and the packaged app build can resolve its file-backed persistence types correctly.
- Restored the generated Xcode project's Swift Package dependency wiring for `SwiftTerm`, keeping local packaging and GitHub Actions archive builds aligned with the package manifest.

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
