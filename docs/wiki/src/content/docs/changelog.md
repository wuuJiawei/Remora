---
title: 更新日志
description: Remora 版本更新历史
---

import { Link } from '@astrojs/starlight/components';

# 更新日志

本页面内容同步自 [GitHub 仓库 CHANGELOG.md](https://github.com/wuuJiawei/Remora/blob/main/CHANGELOG.md)。

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
