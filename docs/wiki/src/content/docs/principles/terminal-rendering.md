---
title: 终端集成
description: Remora 当前的 SwiftTerm 终端集成说明。
---

Remora 当前使用 SwiftTerm 作为终端引擎与视图实现，`RemoraTerminal` 模块只保留适配层与 app 侧集成。

## 当前架构

### SwiftTerm

负责 VT 解析、缓冲区管理、渲染、输入映射、选择与滚动等终端核心能力。

### RemoraTerminal

负责将 SwiftTerm 暴露为 Remora app 侧使用的 `TerminalView`，并桥接输入、尺寸变化与外部链接打开等行为。

### RemoraApp

负责会话管理、SSH/SFTP 工作流、窗口与面板编排，以及 transcript 等应用层状态。
