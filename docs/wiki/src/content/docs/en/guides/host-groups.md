---
title: Host Groups
description: Organize and manage SSH hosts with groups.
---


Remora allows you to organize your SSH hosts into groups for easier management.

## Creating Groups

### Via Settings

1. Open **Settings > Hosts**
2. Click the **+** button next to "Groups"
3. Enter group name
4. (Optional) Choose a color and icon

### Via Context Menu

1. Right-click in the hosts sidebar
2. Select **New Group**
3. Enter group name

## Managing Hosts

### Adding Hosts to Groups

**Method 1: Drag and Drop**
- Drag a host onto a group in the sidebar

**Method 2: Edit Host**
1. Double-click a host or right-click > Edit
2. Select a group from the dropdown

**Method 3: New Host in Group**
- Right-click on a group > **New Host**

### Moving Hosts

- Drag and drop hosts between groups
- Use cut/paste to move hosts

### Host Properties

Each host can have:

| Property | Description |
|----------|-------------|
| **Name** | Display name |
| **Host** | Hostname or IP |
| **Port** | SSH port (default: 22) |
| **Username** | Login username |
| **Group** | Parent group |
| **Auth** | Password or SSH Key |
| **Quick Connect** | Show in quick connect |

## Group Features

### Color Coding
Assign colors to groups for visual organization:
- Red, Orange, Yellow, Green, Blue, Purple

### Collapsible Groups
Groups can be collapsed/expanded to show/hide hosts.

### Nested Groups
Create nested groups for hierarchical organization:
- Folder 1
  - Subfolder A
  - Subfolder B

### Quick Connect
Mark groups as "Quick Connect" to show in quick connect palette.

## Search & Filter

### Search Hosts
- Use the search bar to filter hosts by name
- Search searches across all groups

### Filter by Group
- Click a group header to filter only that group
- Click "All Hosts" to show everything
