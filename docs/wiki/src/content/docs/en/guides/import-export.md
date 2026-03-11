---
title: Import & Export
description: Import existing SSH config or export Remora data.
---

Remora supports importing host configurations from multiple sources and exporting data for backup.

## Importing Config

### Import from SSH Config

Remora can read host configurations from `~/.ssh/config`:

1. Open **Settings > Hosts**
2. Click **Import**
3. Select **Import from SSH Config**
4. Select hosts to import
5. Click **Import**

### Import Formats

Remora supports the following import formats:

| Format | Description |
|--------|-------------|
| SSH Config | `~/.ssh/config` |
| Remora Export | `.remora` file |
| JSON | Generic JSON format |

### JSON Format Example

```json
{
  "hosts": [
    {
      "name": "My Server",
      "host": "192.168.1.100",
      "port": 22,
      "username": "admin",
      "auth": "password"
    }
  ]
}
```

## Exporting Data

### Export as Remora Format

Export all host configurations as a `.remora` file:

1. Open **Settings > Hosts**
2. Click **Export**
3. Select **Export as Remora Format**
4. Choose save location

Exported file contains:

- Host configuration (without passwords)
- Host groups
- Quick commands
- Quick paths

### Export as JSON

Export as generic JSON format for use with other tools:

1. Open **Settings > Hosts**
2. Click **Export**
3. Select **Export as JSON**

## Data Migration

### Migrating to New Device

1. Export config on old device
2. Transfer export file to new device
3. Import config on new device

### Backup Recommendations

Regularly backup your configuration:

- Backup after significant config changes
- Keep export files secure
- Remember your Keychain password
