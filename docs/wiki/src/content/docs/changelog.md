---
title: 更新日志
description: Remora 版本更新历史
---

本页面内容同步自 [GitHub 仓库 CHANGELOG.md](https://github.com/wuuJiawei/Remora/blob/main/CHANGELOG.md)。

## [Unreleased]

## [v0.11.1] - 2026-03-14

### 修复

- SSH 终端会话现在会为启动的 `ssh` 进程补上有效的 `TERM`，依赖终端类型检测的 `top`、`htop` 等 TUI 命令不再因为终端类型缺失而失败。

## [v0.11.0] - 2026-03-13

### 更改

- 终端底层实现已从自研 parser、buffer、renderer、input 栈切换为基于 SwiftTerm 的集成方案。
- `Remora.xcodeproj` 现已和 SwiftTerm 迁移保持一致，Xcode 会正确解析并链接 Swift package 依赖。

### 修复

- 终端 pane 现在重新保留稳定的 10pt 内容呼吸区，不再让终端内容紧贴 pane 边框。
- Xcode 构建不再引用已删除的旧终端源码文件，terminal 迁移后的工程路径恢复可用。

## [v0.10.7] - 2026-03-13

### 新增

- SSH 边栏现在支持拖拽排序顶级分组与 SSH 连接，并支持在分组和未分组平铺列表之间移动连接。
- 新建 SSH 连接时，如果未指定分组，可以直接保留在未分组平铺列表中。
- 会话标签页右键菜单现在提供直接的 SSH 重连操作。
- 项目首页现在提供 Apple Silicon 和 Intel 发布包的直接下载按钮。

### 更改

- 删除 SSH 分组时，现在可以选择同时删除分组内连接，或将这些连接移回未分组列表。
- 会话分屏现在会保留原终端内容，按当前会话上下文创建可用的新 pane，并支持直接关闭新增 pane。

### 修复

- SSH 边栏中的快捷删除和右键删除现在都会先进行二次确认。
- 本地 Shell 会话现在会强制使用 UTF-8 locale，中文文件名和中文命令输入不再乱码。

## [v0.10.6] - 2026-03-12

### 修复

- macOS 发布包现在通过标准 Xcode asset catalog 流程声明应用图标，用户解压后 Finder 与 Dock 会显示同一套图标。
- 移除了仅在运行时覆盖 Dock 图标的旧路径，避免打包 app 在启动前显示通用 Finder 图标。

## [v0.10.5] - 2026-03-12

### 更改

- macOS 打包现在统一走原生 Xcode app archive 流程，本地与 GitHub Actions 共用 `scripts/package_macos.sh`。
- 应用运行时现在从标准 app bundle 读取本地化资源，不再依赖 SwiftPM 资源 bundle 的路径回退逻辑。
- README 与安装文档已同步切换到 `Remora.xcodeproj` 和共享打包脚本这一条主路径。

## [v0.10.4] - 2026-03-08

### 新增

- Shell 光标导航现在支持在活动提示行上直接通过鼠标定位。
- 终端 Shell 编辑模式现在能在 TUI 应用接管屏幕时正确交接键盘输入。

### 更改

- 终端输入现在通过刷新活动面板输出而无需额外帧延迟，响应更即时。
- 终端光标渲染现在会闪烁、与字形度量对齐，并与 IME 位置保持同步。
- 终端缓冲区在宽度变化后重排行为更加可靠。
- 许可证从 Apache-2.0 切换到 MIT。

### 修复

- 左/右方向键移动、Command 光标跳转和提示行鼠标点击现在能正确落在预期的 Shell 位置。
- 终端光标点击测试不再需要多次点击才能稳定在目标列。
- 终端单元格宽度使用精确的字形测量，消除了提示文本和光标之间的可见间隙。
- 无障碍转录快照现在会剥离 Shell 编辑转义序列，而不是暴露原始 ANSI 字节。
- 打包的 app bundle 将 SwiftPM 资源保留在 `Contents/Resources` 下，避免启动时 `Bundle.module` 失败。

## [v0.9.1-open-source-readiness] - 2026-03-04

### 新增

- 开源文档集：
  - `CONTRIBUTING.md`
  - `SECURITY.md`
  - `docs/OPEN_SOURCE_CHECKLIST.md`
- Apache-2.0 `LICENSE`。
- SSH 工作区、终端 TUI 和文件管理器工作流的 README 截图。
- 文件管理器操作反馈 toast（复制/剪切/删除/粘贴/上传/下载/移动/重命名/创建/重试）。
- FTP/SFTP 拖放增强：
  - 上传目标路由（目录目标 vs 当前目录回退）
  - 目标提示覆盖
  -更强的目录拖放目标视觉效果（图标 + 轻微缩放动画）。

### 更改

- 重写 `README.md` 以便公开开源发布，包含完整功能矩阵和更清晰的快速入门/测试文档。
- 将规划文档重组到 `docs/` 并从仓库根目录移除遗留的 OpenSpec 产物。

## [v0.9.0-altscreen-start]

- 备用屏幕和 TUI 兼容性工作的基线里程碑标签。

## [v0.8.0-ssh-reconnect-fixes-start]

- SSH 重连稳定性工作的基线里程碑标签。

## [v0.8.0-pre-major-changes]

- 主要终端/文件管理器功能波之前的基线里程碑标签。

---

*要查看完整更新历史，请访问 [GitHub 上的 CHANGELOG.md](https://github.com/wuuJiawei/Remora/blob/main/CHANGELOG.md)。*
