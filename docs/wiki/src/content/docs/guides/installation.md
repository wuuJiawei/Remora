---
title: Installation
description: How to install Remora on your Mac.
---

# Installation

## Download from GitHub Releases

1. Go to the [Remora Releases](https://github.com/wuuJiawei/Remora/releases) page
2. Download the latest `Remora-x.x.x.dmg` file
3. Open the DMG and drag Remora to your Applications folder
4. (Optional) Remove quarantine: `xattr -dr com.apple.quarantine /Applications/Remora.app`

## Build from Source

```bash
# Clone the repository
git clone https://github.com/wuuJiawei/Remora.git

# Navigate to project directory
cd Remora

# Build
swift build

# Run
swift run RemoraApp
```

## Requirements

- macOS 14.0+
- Xcode 15.4+ (if building from source)
