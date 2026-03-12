---
title: Installation
description: How to install Remora on your Mac.
---


## Download from GitHub Releases

1. Go to the [Remora Releases](https://github.com/wuuJiawei/Remora/releases) page
2. Download the latest `.zip` archive
3. Unzip it
4. Drag `Remora.app` into your Applications folder
5. (Optional) Remove quarantine: `xattr -dr com.apple.quarantine /Applications/Remora.app`

## Build from Source

Open `Remora.xcodeproj` and run the `Remora` scheme for the standard macOS app workflow.

You can also use the command line for development:

```bash
git clone https://github.com/wuuJiawei/Remora.git
cd Remora
swift build
swift run RemoraApp
```

## Package Locally

Local packaging and GitHub Actions use the same script:

```bash
./scripts/package_macos.sh --arch "$(uname -m)" --version 0.0.0-local --build-number 1
```

The packaged archive is written to `dist/`.

## Requirements

- macOS 14.0+
- Xcode 15.4+ (if building from source)
