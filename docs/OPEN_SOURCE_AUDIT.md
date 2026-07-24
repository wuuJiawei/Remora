# Open Source Audit Notes

Last updated: 2026-07-24

This document records the repository-level checks completed before making the project
public. It is not a replacement for manual product validation on real hosts.

## Security And Privacy

### Git history secret scan

- Scanned current tree and git history for common token/private-key patterns.
- No AWS key, GitHub token, Slack token, Google API key, Stripe live key, or PEM/OpenSSH
  private key block patterns were found in tracked history.

### Diagnostics and log redaction

- Remote transport diagnostics use typed operation codes and safe diagnostic messages;
  passwords, private-key contents, and keyboard-interactive responses are not logged.
- The native SSH/SFTP path does not pass credentials through process arguments,
  environment variables, ASKPASS scripts, or `sshpass`.

### Host key trust and credential storage

- Native SSH verifies the presented host key before authentication and exposes first-seen
  or changed keys through typed user decisions.
- `HostKeyStoreTests` covers first-seen, trusted, and changed-key states.
- Native session interaction tests cover host-key, password, passphrase, and
  keyboard-interactive challenge delivery.
- `CredentialStoreTests` covers file-backed read/write/remove behavior, persistence
  across instances, memory cache behavior, and plaintext `credentials.json`
  storage under the local config directory.

## Licensing And Legal

### Bundled assets

- Repository-tracked bundled brand assets are limited to `logo.png`,
  `Resources/AppIcon.icns`, and `Resources/AppIcon.iconset/*`.
- The app uses Apple platform fonts and symbols at runtime rather than shipping third-party
  font files or icon packs in the repository.
- `NOTICE` documents the current redistribution boundary.

### Remaining manual review

- `AGENTS.md` and the agent-oriented implementation-plan docs were removed from the public
  tree.
- `docs/plans/2026-03-11-ssh-import-format-research.md` still contains local-machine
  inspection notes and should be rewritten or removed before checking the final
  “no proprietary/internal docs remain” item.
- Re-check future docs for internal-only roadmap or customer-specific language before
  publishing.
