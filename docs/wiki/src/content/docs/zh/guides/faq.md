---
title: 常见问题
description: 常见问题解答。
---

# 常见问题

## 如何保存密码？

Remora 使用 macOS Keychain 安全存储您的凭据。首次连接时，系统会询问是否保存密码到 Keychain。

## 支持哪些 SSH 密钥格式？

Remora 支持以下 SSH 密钥格式：
- RSA (2048/4096 位)
- ED25519
- ECDSA (256/384/521 位)
- DSA (已废弃)

## 如何导入现有 SSH 配置？

Remora 可以从以下来源导入 SSH 配置：
- SSH config 文件 (`~/.ssh/config`)
- Remora 导出文件 (`.remora`)

## 终端支持哪些功能？

Remora 终端支持：
- ANSI/VT100/VT220 转义序列
- 256 色和真彩色
- xterm 鼠标报告
- 文本选择和复制

## SFTP 传输失败怎么办？

1. 检查网络连接
2. 确认服务器 SFTP 服务正常运行
3. 查看传输日志获取详细错误信息
4. 重试失败的传输任务
