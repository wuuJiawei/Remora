---
title: Import & Export
description: Import existing SSH config or export Remora data.
---

Remora supports importing host configurations from multiple sources and exporting data for backup.

## Importing Config

### Import Formats

Remora supports the following import formats:

- **Remora JSON / CSV**: Import from Remora JSON or CSV file
- **SSH Config**: Import from `~/.ssh/config`
- **WindTerm**: Import from WindTerm user.sessions JSON
- **electerm**: Import from electerm bookmark export JSON
- **Xshell**: Import from Xshell `.xsh`, `.xts`, or `.zip` files
- **PuTTY**: Import from exported PuTTY `.reg` files

### Import Steps

1. Open **Remora > Import Connections**
2. Select import source
3. Select file to import
4. Select hosts to import
5. Click **Import**

## Exporting Data

### Export as JSON

Export host configurations as JSON file:

1. Open **Remora > Export Connections**
2. Select export scope (all or specific group)
3. Select format as **JSON**
4. Choose whether to include saved passwords
5. Choose save location

### Export as CSV

Export as CSV format for spreadsheet processing.

## Data Migration

### Migrating to New Device

1. Export config on old device
2. Transfer export file to new device
3. Import config on new device

### Backup Recommendations

- Regularly backup your configuration
- Keep export files secure
