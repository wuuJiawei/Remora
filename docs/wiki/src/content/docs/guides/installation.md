---
title: 安装
description: 在 macOS 上安装 Remora。
---


## 系统要求

- macOS 14.0 (Sonoma) 或更高版本

## 下载安装

1. 从 [GitHub Releases](https://github.com/wuuJiawei/Remora/releases) 下载最新的 `.dmg` 文件
2. 打开下载的 `.dmg` 文件
3. 将 `Remora.app` 拖入应用程序文件夹

## 信任开发者

首次运行 Remora 时，macOS 可能会阻止应用打开（显示"已损坏"错误）。请运行以下命令移除隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/Remora.app
```

如果仍然无法打开，请到系统设置中手动允许：

1. 打开 **系统设置** → **隐私与安全性**
2. 在安全区域找到被阻止的 Remora 通知
3. 点击 **仍要打开** 并确认
