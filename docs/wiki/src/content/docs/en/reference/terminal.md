---
title: Terminal
description: Terminal features and configuration.
---


Remora includes a custom high-performance terminal engine built from scratch, optimized for modern TUI applications.

## Features

### ANSI/VT Support
- Full ANSI escape sequence support
- 256 color and true color (24-bit) support
- Unicode and emoji support
- Cursor shape reporting

### Selection & Copy
- Click and drag to select text
- Shift+click to extend selection
- Double-click to select word
- Triple-click to select line
- Copy with `Cmd+C` or right-click menu

### Scrollback
- Configurable scrollback buffer (default: 10000 lines)
- Search in scrollback with `Cmd+F`
- Navigate to beginning/end with `Cmd+Home` / `Cmd+End`

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+C` | Copy selected text |
| `Cmd+V` | Paste |
| `Cmd+F` | Search in terminal |
| `Cmd+K` | Clear terminal |
| `Cmd+L` | Clear screen (like clear command) |
| `Cmd+↑/↓` | Scroll up/down |
| `Cmd+Home` | Scroll to beginning |
| `Cmd+End` | Scroll to end |

## Mouse Support

- **Click**: Position cursor
- **Double-click**: Select word
- **Triple-click**: Select line
- **Right-click**: Context menu
- **Scroll**: Navigate history

## TUI Compatibility

Remora's terminal is compatible with:

- ** shells**: bash, zsh, fish, sh
- **Editors**: vim, neovim, nano, emacs
- **Tools**: htop, top, less, more, git
- **Package Managers**: npm, yarn, cargo, pip
