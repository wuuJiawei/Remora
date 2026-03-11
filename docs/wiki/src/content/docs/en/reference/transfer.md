---
title: Transfer Management
description: Manage SFTP file transfer tasks.
---

Remora provides complete file transfer management, including queueing, pause, resume, and more.

## Transfer Queue

All SFTP transfers are managed in a unified queue.

### Viewing the Queue

Click the **Transfers** button in the sidebar, or press `Cmd+Shift+F` to open the transfer panel.

### Queue Status

| Status | Description |
|--------|-------------|
| Pending | Waiting to transfer |
| Transferring | Currently transferring |
| Paused | Transfer paused |
| Completed | Transfer successful |
| Failed | Transfer failed |

## Transfer Operations

### Pause and Resume

- **Pause**: Click pause button to pause current transfer
- **Resume**: Click resume button to continue
- Paused transfers can be resumed anytime

### Cancel Transfer

- Click cancel to terminate the transfer
- Partially transferred files are kept

### Retry Failed Transfers

- Click retry to retransfer failed files
- Supports resume from break point (when server supports)

## Transfer Settings

Configure in **Settings > File Manager > Transfers**:

### Concurrent Transfers

Set maximum simultaneous transfer tasks (default: 3).

### Transfer Buffer

Set file transfer buffer size, affecting transfer speed and memory usage.

### Overwrite Strategy

Choose action when file already exists:

- **Ask**: Ask user each time
- **Overwrite**: Overwrite directly
- **Skip**: Skip the file
- **Rename**: Auto-rename to new name

### Preserve Timestamps

When enabled, uploads/downloads preserve original file timestamps.

## Resume Support

Remora supports resuming interrupted transfers from where they left off.

### Requirements

- Server SFTP service supports resume
- **Resume Support** enabled in transfer settings

### Usage

When transfer fails, click **Retry** to continue from the break point.
