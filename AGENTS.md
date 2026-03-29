# AGENTS

## Project rules

- Any user-facing copy must support localization. Use `tr(...)` for UI strings and add/update entries in both `Sources/RemoraApp/Resources/en.lproj/Localizable.strings` and `Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings`.
- Any UI change must support both light mode and dark mode. Prefer theme-aware colors/styles already used in the codebase and verify the UI in both appearances before finishing the work.
- Any UI change must preserve the existing native macOS style. Prefer SwiftUI native controls and behaviors first, and only introduce custom-styled UI when the existing codebase already establishes that pattern or the product explicitly requires it.
- Any git worktree created for this project must live under the repository-local `.worktree/` directory. Do not create project worktrees alongside the repository or outside `.worktree/`.
- If a worktree path changes after SwiftPM/Xcode has already built in it, clear SwiftPM build caches in that worktree before running again, for example with `swift package clean` and `swift package reset`, to avoid stale module cache path errors.
