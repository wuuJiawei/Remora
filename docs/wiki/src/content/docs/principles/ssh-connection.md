---
title: SSH 连接复用
description: 高效 SSH 连接管理机制。
---

Remora 采用 SSH 连接复用技术，大幅提升多会话场景下的性能。

## SSHConnectionReuse

连接池管理，重复利用已建立的 SSH 通道。

> 敬请期待：复用策略详解

## 会话管理

### SessionManager

统一管理所有 SSH 会话，支持动态创建和销毁。

> 敬请期待：连接生命周期
