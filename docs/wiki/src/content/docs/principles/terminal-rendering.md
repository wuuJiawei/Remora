---
title: 终端渲染引擎
description: 自研 CoreText 终端渲染器解析。
---

Remora 的终端渲染引擎完全自研，基于 CoreText 框架构建。

## 核心架构

### CoreTextTerminalRenderer

使用 CoreText 直接绘制文本字符，实现高精度渲染。

### GlyphCache 字形缓存

智能字形缓存，避免重复渲染相同字符，大幅提升性能。

> 敬请期待：渲染管线详解

## 屏幕缓冲

### ScreenBuffer

双缓冲机制，确保渲染无闪烁。

### ScrollbackStore

可配置的回滚存储，保存历史输出。

> 敬请期待：内存优化策略

## 性能优化

### FrameScheduler

智能帧调度，按需渲染，节省 CPU 资源。

> 敬请期待：帧率控制原理
