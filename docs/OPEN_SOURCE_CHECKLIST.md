# Open Source Readiness Checklist

Use this checklist before making the repository public.

## 1. Security & Privacy

- [ ] Confirm no secrets/tokens/private keys are present in git history.
- [ ] Review logs/diagnostics to ensure sensitive data is redacted.
- [ ] Validate host key trust flow and credential storage behavior.
- [ ] Ensure `SECURITY.md` reflects the correct private contact channel.

## 2. Licensing & Legal

- [x] Add top-level `LICENSE` (Apache-2.0).
- [ ] Verify all bundled assets/fonts/icons are redistributable.
- [ ] Add `NOTICE` file if third-party notices are required.
- [ ] Confirm no proprietary/internal docs remain in public tree.

## 3. Documentation Quality

- [x] Rewrite `README.md` with clear quick start and feature overview.
- [x] Add `CONTRIBUTING.md`.
- [x] Add `SECURITY.md`.
- [ ] Add screenshots/GIFs for core workflows (terminal, SSH, file manager).
- [ ] Add architecture diagram for `RemoraCore` / `RemoraTerminal` / `RemoraApp`.

## 4. Build & CI

- [ ] Add CI workflow for `swift build` + targeted tests.
- [ ] Add optional CI lane for UI automation (separate/manual trigger).
- [ ] Enforce formatting/lint strategy (if adopted).

## 5. Product Readiness

- [ ] Validate local shell, SSH auth modes, reconnect flow on real hosts.
- [ ] Validate SFTP operations on at least 2 server distributions.
- [ ] Validate CJK input and terminal selection behaviors.
- [ ] Validate drag/drop upload targets and operation toasts.

## 6. Release Hygiene

- [ ] Decide versioning policy (SemVer suggested).
- [ ] Create initial changelog (`CHANGELOG.md`).
- [ ] Tag first public release and attach release notes.
- [ ] Add issue templates and PR template.

## 7. Community Setup (Recommended)

- [ ] Add `CODE_OF_CONDUCT.md`.
- [ ] Add `SUPPORT.md` (where to ask usage questions).
- [ ] Configure Discussions (optional).

