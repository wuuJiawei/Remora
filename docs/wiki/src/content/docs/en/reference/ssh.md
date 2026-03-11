---
title: SSH
description: SSH connection and session management reference.
---


## Connection Management

### Adding Hosts

1. Click the **+** button in the hosts sidebar
2. Enter connection details:
   - **Host**: hostname or IP address
   - **Port**: SSH port (default: 22)
   - **Username**: your login username
   - **Authentication**: Password or SSH key

### SSH Keys

Remora supports:
- RSA (2048/4096)
- Ed25519
- ECDSA

Place your keys in `~/.ssh/` directory.

## Session Features

- **Multi-tab**: Open multiple SSH sessions in tabs
- **Split Pane**: Split terminal horizontally or vertically
- **Quick Commands**: Save frequently used commands
- **Quick Paths**: Save frequently visited directories

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New tab |
| `Cmd+W` | Close tab |
| `Cmd+[` | Previous tab |
| `Cmd+]` | Next tab |
