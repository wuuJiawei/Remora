# Security Hardening Design

**Date:** 2026-03-06

## Goal

Harden Remora's SSH credential handling and file transfer behavior without breaking normal connection, export, clipboard, or download workflows.

## Scope

- Move saved credentials from a plaintext file to Keychain-backed storage with in-memory caching.
- Add explicit consent and warning UX for saving passwords and exporting saved passwords.
- Stop copying passwords to the clipboard and stop exporting them by default.
- Remove prompt-string-based SSH password autofill and use explicit password transport helpers instead.
- Stream remote downloads directly to disk for file transfer flows.
- Harden copied SSH commands and SFTP batch argument quoting.

## Non-Goals

- Redesign the host editor or export flow beyond the warning and consent requirements.
- Add cloud sync or cross-device credential sharing.
- Change the existing host catalog encryption format.

## Constraints

- Preserve existing normal SSH/SFTP usage.
- Prefer native macOS APIs and keep the UI consistent with existing SwiftUI patterns.
- Keep password reads low-friction by caching the first Keychain read in memory for the app session.
- Avoid silently reintroducing plaintext password persistence anywhere else.

## Design

### Credential Storage

- `CredentialStore` becomes a Keychain-backed actor.
- The store keeps an in-memory cache keyed by credential reference.
- `setSecret` writes to Keychain and memory.
- `secret` checks memory first, then reads once from Keychain and caches the result.
- `removeSecret` removes from both memory and Keychain.
- Existing tests are updated to exercise Keychain semantics through isolated service/account namespaces.

### Save Password UX

- The existing “Save password” toggle is relabeled to make the storage target explicit.
- First-time enablement shows a strong warning explaining:
  - the password is stored in macOS Keychain,
  - it is used only for SSH/SFTP authentication,
  - it is not uploaded or reused for other features.
- The user can continue or cancel without losing editor state.

### Export and Clipboard Safety

- Connection export defaults to no password material.
- Export UI adds an explicit “include saved passwords” option, default off.
- If enabled, a second destructive-style confirmation explains the risks of writing plaintext passwords to disk.
- “Copy connection info” excludes passwords entirely.
- Copied SSH commands quote username and address safely for shell paste use.

### SSH Password Authentication

- `SystemSSHClient` stops scanning terminal output for `password:`.
- Password authentication uses the same explicit helper strategy already present in `SystemSFTPClient`: `sshpass` when available, otherwise `SSH_ASKPASS`.
- This prevents accidental password disclosure to the remote shell.

### Streaming Downloads

- `SFTPClientProtocol` gains a download-to-local-file API with progress reporting.
- `SystemSFTPClient` implements direct-to-file download for both SFTP and SSH fallback paths.
- File transfer downloads use the streaming API instead of materializing the entire remote file in memory.
- Existing text-editing flows may continue using the `Data` API for now.

### Boundary Hardening

- SFTP batch argument quoting also escapes embedded newlines and carriage returns.
- Any command text copied for terminal use is shell-safe.

## Testing Strategy

- Update unit tests for `CredentialStore`, `HostConnectionExporter`, `HostConnectionClipboardBuilder`, `SystemSSHClient`, `SystemSFTPClient`, and `FileTransferViewModel`.
- Add focused tests for:
  - Keychain-backed secret persistence and cache behavior,
  - export defaults and opt-in password export,
  - clipboard text excluding passwords,
  - SSH launch configuration for password auth,
  - direct-to-file download behavior,
  - quoting edge cases.
- Run targeted `swift test --filter ...` commands per sub-task, then a broader focused suite at the end.

## Commit Plan

1. Add design and implementation plan docs.
2. Implement Keychain credential storage and password-save warning.
3. Harden export, clipboard, and copied SSH command behavior.
4. Replace SSH prompt sniffing with explicit password helpers and harden batch quoting.
5. Stream downloads directly to disk and verify transfer regressions.
