# Changelog

All notable changes to this project will be documented in this file.

This project generally follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html), with pre-release style suffixes where needed during active iteration.

## [Unreleased]

## [v0.15.0] - 2026-03-30

### English

#### Added

- Added a tabbed server monitoring dashboard with dedicated Overview, Network, and Process views, sortable monitoring tables, localized tab labels, and a denser layout for live operational data.
- Added native terminal context-menu actions with visible shortcut hints so copy, paste, clear, and related terminal workflows are easier to discover from the mouse path.
- Added a prominent sidebar create-connection entry point so new SSH hosts can be created directly from the main sidebar workflow.
- Added a GitHub release update checker in Settings so Remora can detect newer published versions and show release notes inline before users leave the app.

#### Changed

- Upgraded the embedded SwiftTerm dependency to `1.13.0` to pick up recent macOS terminal fixes and keyboard-behavior improvements.
- Refined the monitoring presentation so longer process command lines stay more readable and the new multi-tab monitoring flow feels more stable in the dedicated status window.

#### Fixed

- Fixed server monitoring snapshots so process rows retain full command-line context instead of dropping important details from running commands.
- Fixed regressions in the monitoring feature wave so packaged builds now include the latest monitoring sort-order sources and runtime behavior matches local development builds.

#### Internal

- Stabilized asynchronous file-transfer and terminal directory-sync tests to reduce CI-only timing flakes around runtime coordination paths.
- Updated the generated Xcode project and release packaging metadata so the shipped app stays aligned with the current SwiftPM source layout and release-checker implementation.

### 中文

#### 新增

- 新增标签页式服务器监控面板，提供 Overview、Network、Process 三个独立视图，支持可排序的监控表格、本地化标签标题，以及更适合实时运维数据的紧凑布局。
- 新增原生终端右键菜单操作，并直接展示对应快捷键提示，让复制、粘贴、清屏等常用终端操作在鼠标路径下也更容易发现。
- 在侧边栏中新增更显眼的新建连接入口，可以直接从主侧边栏工作流创建新的 SSH 主机。
- 在设置中新增 GitHub Release 更新检查器，Remora 现在可以检测是否有新版本，并在应用内直接展示对应的更新说明。

#### 变更

- 将内置 SwiftTerm 依赖升级到 `1.13.0`，纳入近期 macOS 终端修复和键盘行为改进。
- 调整了服务器监控展示方式，让更长的进程命令行保持可读，并让新的多标签监控流程在独立状态窗口中更稳定自然。

#### 修复

- 修复了服务器监控快照中的进程采集问题，进程行现在会保留完整命令行上下文，不再丢失正在运行命令的重要信息。
- 修复了这一轮监控功能迭代带来的集成回归，打包构建现在会包含最新的监控排序逻辑源码，并与本地开发构建保持一致的运行时行为。

#### 内部

- 稳定了文件传输和终端目录同步相关的异步测试，减少运行时协同路径在 CI 中偶发的时序抖动。
- 更新了生成式 Xcode 工程和发布打包元数据，确保最终发布的应用始终与当前 SwiftPM 源码布局和更新检查实现保持一致。

## [v0.14.3] - 2026-03-27

### English

#### Added

- Added a richer server monitoring dashboard with overview cards, top-process snapshots, network and disk throughput rates, filesystem usage, and a lightweight session-metrics hover tooltip anchored to the hovered status tag.
- Added recursive remote directory downloads from file menus and bottom-bar actions so entire folders can be materialized locally without falling back to manual file-by-file downloads.
- Added live transfer queue speed tracking, batch-aware progress aggregation, pin/unpin behavior for the floating queue, and stop controls for individual transfers or the whole active queue.
- Added a private-key file picker in the SSH host editor so key-based connections can be configured without manually pasting file paths.

#### Changed

- Refined the server-status experience around the dedicated monitoring window, widened the layout for denser metrics, and aligned the dashboard cards and hover affordances with the expanded monitoring workflow.
- Updated file-manager context menus to use grouped native icons and expanded batch-download actions so mixed selections can download directories and files more consistently.

#### Fixed

- Fixed AI settings persistence so API key reads and writes always happen on the main actor, avoiding state-update races from background contexts.
- Fixed system-backed upload and download progress reporting so SSH-streaming transfers surface live progress and speed information instead of jumping directly from idle to complete.
- Fixed SSH directory listing fallback handling so empty shell-based listings are accepted when remote folders are legitimately empty, instead of being treated as a failed fallback.
- Fixed cancellation plumbing for queued and running transfers so stopping a transfer releases queue slots correctly and cleans up unfinished local download targets when appropriate.

#### Internal

- Refactored `ContentView` into focused layout, sidebar, sheet, support, and session component modules to make the main workspace easier to maintain without changing the product workflow.
- Expanded regression coverage for transfer progress, diagnostics, monitoring panels, context-menu behavior, localized clipboard/importer flows, and other asynchronous host/transfer edge cases touched in this release.
- Updated the packaging flow to regenerate the Xcode project before building release archives so packaged builds stay aligned with the current SwiftPM source layout.

### 中文

#### 新增

- 新增更完整的服务器监控面板，提供总览卡片、Top 进程快照、网络与磁盘吞吐速率、文件系统占用信息，以及锚定到当前状态标签的轻量级会话指标悬浮提示。
- 新增远程目录递归下载能力，可直接从文件菜单和底部操作栏把整个目录完整下载到本地，不再需要逐个文件手动下载。
- 新增传输队列实时速度显示、按批次聚合的总体进度、浮动队列的固定/取消固定能力，以及单任务和整队列的停止控制。
- 在 SSH 主机编辑器中新增私钥文件选择器，配置基于私钥的连接时不再需要手动粘贴文件路径。

#### 变更

- 围绕独立监控窗口重构了服务器状态体验，扩展了窗口宽度与指标布局，并让监控卡片和悬浮提示更适配增强后的监控工作流。
- 调整了文件管理器右键菜单，改用分组的原生图标展示，并扩展批量下载行为，使混合选择目录和文件时的下载操作更一致。

#### 修复

- 修复了 AI 设置持久化的线程问题，API Key 的读取和写入现在始终在主线程执行，避免后台上下文触发状态更新竞态。
- 修复了系统级上传/下载的进度上报逻辑，使 SSH streaming 路径下的传输也能实时显示进度与速度，而不是从空闲直接跳到完成。
- 修复了 SSH 目录列表回退逻辑：当远程目录本身为空时，现在会正确接受 shell fallback 的空结果，而不再误判为回退失败。
- 修复了排队中和运行中传输任务的取消链路，停止任务后会正确释放传输槽位，并在合适场景下清理未完成的本地下载目标。

#### 内部

- 将 `ContentView` 拆分为布局、侧边栏、弹窗、支持类型和会话组件等聚焦模块，在不改变产品工作流的前提下提升主工作区的可维护性。
- 扩展了传输进度、诊断日志、监控面板、右键菜单行为、本地化剪贴板/导入流程以及其他主机/传输异步边界场景的回归测试覆盖。
- 更新了打包流程：在构建发布归档前先重生成 Xcode 工程，确保打包产物始终与当前 SwiftPM 源码布局保持一致。

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
