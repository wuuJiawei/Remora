# Contributing to Remora

Thanks for your interest in Remora.

## Ground Rules

- Be respectful and collaborative.
- Keep pull requests focused and reviewable.
- Prefer simple, testable changes over broad rewrites.

## Development Setup

### Requirements

- macOS 14+
- Xcode 15.4+ (or Swift 6 toolchain)

### Build

```bash
swift build
```

### Run App

```bash
swift run RemoraApp
```

### Run Tests

```bash
swift test
```

UI automation tests are opt-in:

```bash
REMORA_RUN_UI_TESTS=1 swift test --filter RemoraUIAutomationTests
```

## Branches & Commits

- Create feature branches from `main`.
- Keep commits small and meaningful.
- Use imperative commit messages, for example:
  - `Fix terminal selection anchor after scroll`
  - `Add SFTP drop destination hint`

## Pull Request Checklist

Before opening a PR:

- [ ] Build succeeds locally.
- [ ] Relevant tests pass locally.
- [ ] New behavior includes tests where practical.
- [ ] User-facing changes include localization updates (`en` / `zh-Hans`) if needed.
- [ ] Docs are updated when behavior or APIs change.

In the PR description, include:

- What changed.
- Why it changed.
- How it was tested.
- Screenshots/GIFs for UI changes (recommended).

## Reporting Issues

Please include:

- macOS version
- Remora commit/tag
- Repro steps
- Expected vs actual behavior
- Logs/screenshots (if available)

Use GitHub Issues: <https://github.com/wuuJiawei/Remora/issues>

## Security Issues

Please do not post sensitive vulnerabilities publicly first.

For security-related reports, follow `SECURITY.md`.
