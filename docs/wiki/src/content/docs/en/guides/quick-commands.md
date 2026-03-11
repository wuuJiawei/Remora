---
title: Quick Commands & Paths
description: Save and use frequently used commands and directories.
---


Remora allows you to save frequently used commands and directory paths for quick access.

## Quick Commands

### Creating a Quick Command

1. Open **Settings > Quick Commands**
2. Click the **+** button
3. Enter:
   - **Name**: Display name (e.g., "Git Status")
   - **Command**: The command to execute (e.g., `git status`)
   - **Working Directory**: (Optional) Directory to run in
   - **Description**: (Optional) Description

### Using Quick Commands

- **Keyboard**: Press `Cmd+Shift+K` to open quick command palette
- **Menu**: Access from **Sessions > Quick Commands** menu

### Example Commands

| Name | Command |
|------|---------|
| Git Status | `git status` |
| Git Pull | `git pull` |
| NPM Install | `npm install` |
| Docker PS | `docker ps` |
| Top Processes | `htop` |

## Quick Paths

### Creating a Quick Path

1. Open **Settings > Quick Paths**
2. Click the **+** button
3. Enter:
   - **Name**: Display name (e.g., "Project Root")
   - **Path**: Directory path (e.g., `/Users/you/project`)
   - **Description**: (Optional) Description

### Using Quick Paths

- **Keyboard**: Press `Cmd+Shift+P` to open quick path palette
- **Menu**: Access from **Sessions > Quick Paths** menu

### Sync with File Manager

Enable **Sync Terminal with File Manager** in settings to automatically change terminal directory when navigating in the file manager.

## Variables

Quick commands support the following variables:

| Variable | Description |
|----------|-------------|
| `$HOST` | Current host name |
| `$USER` | Current user name |
| `$CWD` | Current working directory |
| `$DATE` | Current date (YYYY-MM-DD) |
| `$TIME` | Current time (HH:MM:SS) |
