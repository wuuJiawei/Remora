# Open Source Readiness Checklist

Use this checklist before making the repository public.

## 1. Security & Privacy

- [x] Confirm no secrets/tokens/private keys are present in git history.
- [x] Review logs/diagnostics to ensure sensitive data is redacted.
- [x] Validate host key trust flow and credential storage behavior.
- [x] Ensure `SECURITY.md` reflects the correct private contact channel.

## 2. Licensing & Legal

- [x] Add top-level `LICENSE` (MIT).
- [x] Verify all bundled assets/fonts/icons are redistributable.
- [x] Add `NOTICE` file if third-party notices are required.
- [ ] Confirm no proprietary/internal docs remain in public tree.

## 3. Documentation Quality

- [x] Rewrite `README.md` with clear quick start and feature overview.
- [x] Add `CONTRIBUTING.md`.
- [x] Add `SECURITY.md`.
- [x] Add screenshots/GIFs for core workflows (terminal, SSH, file manager).
- [x] Add architecture diagram for `RemoraCore` / `RemoraTerminal` / `RemoraApp`.

## 4. Build & CI

- [x] Add CI workflow for `swift build` + targeted tests.
- [x] Add optional CI lane for UI automation (separate/manual trigger).
- [ ] Enforce formatting/lint strategy (if adopted).

## 5. Product Readiness

- [ ] Validate local shell startup, resize, transcript, copy/paste, and working-directory behavior.
- [ ] Validate SSH auth matrix on real hosts (agent / private key / password) plus wrong-credential handling.
- [ ] Validate first-seen host key prompt, changed-key handling, disconnect, and reconnect flow.
- [ ] Validate terminal interaction on real hosts: CJK input, IME caret placement, selection/copy, shell cursor movement, and TUI alternate screen.
- [ ] Validate SFTP navigation and CRUD operations on at least 2 server distributions.
- [ ] Validate file-manager binding across tabs/panes and remote state restore.
- [ ] Validate upload/download paths, drag/drop destination targeting, conflict handling, retry, and operation toasts.
- [ ] Run through [`docs/real-ssh-acceptance-checklist.md`](./real-ssh-acceptance-checklist.md) and record pass/fail evidence.

## 6. Release Hygiene

- [x] Decide versioning policy (SemVer suggested).
- [x] Create initial changelog (`CHANGELOG.md`).
- [ ] Tag first public release and attach release notes.
- [x] Add issue templates and PR template.

## 7. Community Setup (Recommended)

- [x] Add `CODE_OF_CONDUCT.md`.
- [x] Add `SUPPORT.md` (where to ask usage questions).
- [ ] Configure Discussions (optional).
