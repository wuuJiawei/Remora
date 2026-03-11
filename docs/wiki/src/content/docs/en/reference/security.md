---
title: Security Settings
description: Learn about Remora's security mechanisms and configuration options.
---

Remora uses a local-first security strategy to protect your credentials and connections.

## Credential Storage

### Keychain Storage (Recommended)

Remora uses macOS Keychain to securely store passwords:

- Passwords encrypted in system Keychain
- Credentials won't leak after app exit
- Asked to save on first connection

### Temporary Storage

You can also choose to store passwords only during the session:

- Password stored only in memory
- Cleared when app closes or disconnects
- Suitable for public devices

## SSH Keys

### Supported Key Formats

Remora supports the following SSH key formats:

- RSA (2048/4096 bits)
- ED25519
- ECDSA (256/384/521 bits)

### Key Locations

Key files are typically stored in `~/.ssh/`:

```
~/.ssh/id_rsa
~/.ssh/id_ed25519
~/.ssh/id_ecdsa
```

### Key Permissions

Ensure private key permissions are correct:

```bash
chmod 600 ~/.ssh/id_ed25519
```

## Host Fingerprints

### StrictHostKeyChecking

When connecting to a new host for the first time, Remora displays the host fingerprint for confirmation:

- **Ask (default)**: Show fingerprint, save after confirmation
- **Accept**: Auto-accept and save fingerprint
- **Reject**: Reject connection

### Managing Known Hosts

In **Settings > SSH > Security** you can:

- View saved host fingerprints
- Delete individual or all saved fingerprints
- Re-verify host fingerprints

## Sensitive Operation Confirmation

Remora requires confirmation for the following sensitive operations:

- Copy plaintext password to clipboard
- Export passwords
- Disable key storage
- Delete saved hosts

## Security Logs

Check **Settings > Advanced > Debug Logs** for security-related logs to help troubleshoot issues.
