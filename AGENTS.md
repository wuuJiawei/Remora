# AGENTS

## Project Overview

Remora 是一个原生 macOS SSH/SFTP 客户端，使用 Swift 6 + SwiftUI 构建，最低支持 macOS 14+。项目采用 Swift Package Manager 管理。

## Module Boundary Rules

| 模块 | 职责 |
|---|---|
| `RemoraCore` | SSH、SFTP、主机模型、凭据处理、主机密钥信任、共享会话抽象 |
| `RemoraTerminal` | SwiftTerm 适配层 + 终端视图集成 |
| `RemoraApp` | SwiftUI 应用外壳、工作区 UI、设置、文件管理器、传输流程 |

- `RemoraApp` 拥有面向用户的工作流和展示状态。
- `RemoraTerminal` 专注于终端集成，将 SwiftTerm 与应用层隔离。
- `RemoraCore` 拥有传输、持久化、安全和可复用的领域逻辑。
- App 层功能应优先依赖 `RemoraCore` 和 `RemoraTerminal`，不得在 UI 层重新实现协议或解析器行为。

## Localization (i18n)

- 所有用户可见的文本必须使用 `tr(...)` 包裹（定义于 `Sources/RemoraApp/LocalizationHelpers.swift`）。
- 必须同步更新以下两个翻译文件：
  - `Sources/RemoraApp/Resources/en.lproj/Localizable.strings`（英文）
  - `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`（简体中文）
- 国际化通过 `L10n.tr()` 实现，支持运行时语言切换（通过 `AppPreferences` 中的 `languageModeRawValue`）。

## UI Rules

- 所有 UI 变更必须同时支持 **Light Mode** 和 **Dark Mode**。优先使用代码库中已有的主题感知颜色/样式（参见 `AppAppearanceMode`），完成前需在两种外观下验证。
- 所有 UI 变更必须保持现有**原生 macOS 风格**。优先使用 SwiftUI 原生控件和行为，仅当代码库已建立自定义模式或产品明确要求时才引入自定义样式。

## Git & Build Rules

- 从 `main` 分支创建功能分支。
- 提交保持小而有意义，使用祈使语气的提交信息（如 `Fix terminal selection anchor after scroll`）。
- 任何 git worktree 必须创建在仓库本地的 `.worktree/` 目录下，不得在仓库旁边或外部创建。
- 如果 worktree 路径在 SwiftPM/Xcode 构建后发生变化，须先清理构建缓存（`swift package clean` && `swift package reset`），以避免模块缓存路径错误。

## Development Environment

- **环境要求**：macOS 14+，Xcode 15.4+（或 Swift 6 工具链）
- **构建**：`swift build`
- **运行**：`swift run RemoraApp`
- **测试**：`swift test`
- **UI 自动化测试**（可选）：`REMORA_RUN_UI_TESTS=1 swift test --filter RemoraUIAutomationTests`

## Pull Request Checklist

- [ ] 本地构建成功（`swift build`）
- [ ] 相关测试本地通过（`swift test`）
- [ ] 新行为尽可能包含测试
- [ ] 用户可见的变更包含国际化更新（`en` / `zh-Hans`）
- [ ] 行为或 API 变更时更新文档
- [ ] UI 变更在 Light / Dark 两种模式下验证通过
- [ ] PR 描述包含：变更内容、变更原因、测试方式
- [ ] UI 变更附带截图或 GIF

## Security

- 安全漏洞**不得**公开发布，需邮件报告至 `wujiawei0926@gmail.com`（主题前缀 `[Remora Security]`）。
- 重点安全关注领域：凭据/密钥处理、主机密钥验证、命令注入风险、路径遍历、敏感日志泄漏。

## Code Style & Conventions

- Swift 工具链版本：6.0（`// swift-tools-version: 6.0`）
- 默认本地化语言：`en`
- 枚举偏好使用 `String` 原始值 + `CaseIterable` + `Identifiable` 模式（参见 `AppAppearanceMode`、`AppLanguageMode`）。
- 偏好设置通过 `AppPreferences` 单例 + `Codable` 快照模式管理（参见 `AppPreferencesSnapshot`）。
- 框架链接通过 `Package.swift` 中的 `linkerSettings` 显式声明。

###
- 对于功能修改尽量做最小修改，
