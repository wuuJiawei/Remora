# FTP Popups, Sorting, and Permissions Design

**Status:** Approved for implementation

**Goal**

Deliver three FTP/file-manager improvements in the existing Swift macOS app:

1. Add a quick download icon button inside the remote editor popup and the remote live log viewer popup.
2. Make the entire sortable FTP table headers clickable, not just the text/icon hotspot.
3. Add a separate `Edit Permissions` flow from the FTP item context menu with visual rwx editing, synchronized numeric mode editing, owner/group fields, and an optional recursive apply toggle.

These three requirements will be implemented, tested, and committed independently.

---

## Requirement 1: Download button in editor and live viewer popups

### Current state

- `RemoteTextEditorSheet.swift` already has a top bar with path display and a copy-path icon button.
- `RemoteLogViewerSheet.swift` already has a top section with path display plus inline controls such as follow/line count/refresh.
- Both sheets already receive access to `FileTransferViewModel` either directly or through their view models.

### Desired behavior

- Add a download icon button to each popup.
- The button should queue a download for the currently opened remote file.
- The action should be visually lightweight and consistent with the existing popup toolbar actions.
- Success feedback can reuse the existing toast pattern already used for path copy actions.

### Design choice

- Place the button near the existing path/copy controls so the popup-level file actions stay grouped together.
- Use the same iconography and accessibility conventions across both sheets.
- Reuse a shared helper where practical so the popup action semantics stay consistent.

### Acceptance criteria

- Editor popup shows a download icon button.
- Live viewer popup shows a download icon button.
- Clicking either queues a download for the current file path.
- Existing popup actions still work.

---

## Requirement 2: Full-header clickable sorting

### Current state

- Sorting state already exists in `FileManagerPanelView.swift` via `remoteSortColumn` and `isRemoteSortAscending`.
- Sort toggling logic already exists; the usability problem is the clickable target area of the header.

### Desired behavior

- Clicking anywhere in a sortable header cell should trigger sorting.
- Users should not need to precisely click on the header label or the tiny sort indicator.
- Existing sort direction behavior should remain unchanged.

### Design choice

- Keep the current sort state and sort indicator logic.
- Expand the hit area of each sortable header to the entire header cell using a button/content-shape approach.
- Preserve current visual feedback and sorting semantics.

### Acceptance criteria

- Each sortable FTP header cell is clickable across its full width/height.
- Existing sort direction toggling still works.
- Existing column ordering behavior remains unchanged.

---

## Requirement 3: Separate Edit Permissions flow

### Current state

- `RemoteFilePropertiesSheet.swift` currently exposes a simple permissions text field plus basic metadata display.
- `RemoteFilePropertiesViewModel.swift` already loads and saves `RemoteFileAttributes`.
- `RemoteFileAttributes` and `setAttributes(...)` already support permissions, owner, and group.
- The FTP item context menu already exposes `Properties`.

### Desired behavior

- Add a separate `Edit Permissions` action to the FTP item context menu.
- Opening that action should present a dedicated permissions editor, not overload the current lightweight properties sheet.
- The editor should support:
  - owner / group / public rwx toggles
  - numeric mode input (for example `0777` or `755`)
  - two-way synchronization between checkboxes and the numeric mode field
  - editable user field
  - editable group field
  - a toggle or checkbox for recursively applying changes to child items

### Design choice

- Keep `Properties` as the lightweight metadata sheet.
- Introduce a separate `RemotePermissionsEditorSheet` (or equivalent focused file) for edit-heavy permissions work.
- Keep parsing/formatting logic out of the sheet body as much as possible by moving synchronization logic into a dedicated view model/helper.
- If recursive apply cannot be completed through the current lowest-level API without additional orchestration, implement the recursion at the app/view-model layer rather than duplicating chmod/chown logic in the UI.

### Acceptance criteria

- FTP item context menu shows a distinct `Edit Permissions` entry.
- The permissions editor supports rwx toggles for owner/group/public.
- Numeric mode and checkbox state stay synchronized in both directions.
- User and group fields are editable.
- Recursive apply is exposed through a checkbox/toggle.
- Saving updates remote attributes through a single clear flow.

---

## Commit strategy

These requirements must be implemented and committed independently:

1. Popup download buttons
2. Full-header sorting hit area
3. Permissions editor flow

Each requirement gets:

- its own TDD cycle
- its own focused verification
- its own commit
