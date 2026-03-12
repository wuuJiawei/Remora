---
title: 安装
description: 在 macOS 上安装 Remora。
---


## 系统要求

- macOS 14.0 (Sonoma) 或更高版本

## 下载安装

1. 从 [GitHub Releases](https://github.com/wuuJiawei/Remora/releases) 下载最新的 `.zip` 压缩包
2. 解压下载的 `.zip` 文件
3. 将 `Remora.app` 拖入应用程序文件夹

## 从源码运行

推荐直接打开仓库根目录下的 `Remora.xcodeproj`，运行 `Remora` scheme。

命令行开发运行：

```bash
git clone https://github.com/wuuJiawei/Remora.git
cd Remora
swift build
swift run RemoraApp
```

## 本地打包

本地打包与 GitHub Actions 使用同一条脚本：

```bash
./scripts/package_macos.sh --arch "$(uname -m)" --version 0.0.0-local --build-number 1
```

产物会输出到 `dist/` 目录。

## 信任开发者

首次运行 Remora 时，macOS 可能会阻止应用打开（显示"已损坏"错误）。请运行以下命令移除隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/Remora.app
```

如果仍然无法打开，请到系统设置中手动允许：

1. 打开 **系统设置** → **隐私与安全性**
2. 在安全区域找到被阻止的 Remora 通知
3. 点击 **仍要打开** 并确认
