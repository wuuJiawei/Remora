# Product Readiness Acceptance Checklist

Use this checklist for manual acceptance before a public release.

Recommended coverage:

- 1 local shell session on the release machine
- 2 real SSH hosts on different server distributions
- at least 1 host using agent auth
- at least 1 host using password or private-key auth
- one host/path combination suitable for upload, download, rename, and delete testing

## Environment
- [ ] macOS version recorded
- [ ] Remora commit hash recorded
- [ ] Host A/B connection metadata prepared (host, port, username, auth method)
- [ ] Accessibility permission enabled (for optional UI automation run)

## Local Shell Baseline
- [ ] Local shell tab opens successfully
- [ ] Initial prompt appears without overlap/flicker
- [ ] `pwd` reflects the expected local working directory
- [ ] Typing, backspace, and paste behave normally
- [ ] Resize keeps transcript readable and prompt usable
- [ ] Local copy/select behavior works as expected

## SSH Connection & Authentication
- [ ] Host A connects successfully
- [ ] Host B connects successfully
- [ ] Agent authentication succeeds on at least one host
- [ ] Password or private-key authentication succeeds on at least one host
- [ ] Wrong username/password/key shows explicit failure state
- [ ] Unreachable host shows explicit failure state
- [ ] First-seen host key prompt is understandable and actionable
- [ ] Changed host key produces a clear warning/failure path
- [ ] Disconnect action updates UI to `Disconnected`
- [ ] Reconnect after disconnect succeeds

## Interactive Terminal Behavior
- [ ] Prompt is visible after connect
- [ ] `whoami` returns expected username
- [ ] `pwd` returns expected working directory
- [ ] `ls` output renders without overlap/flicker
- [ ] Enter creates proper newline separation
- [ ] Backspace edits command line correctly
- [ ] Left/right arrows do not corrupt prompt prefix
- [ ] Mouse-based shell cursor positioning lands on the intended prompt column
- [ ] Selection and copy behave correctly across wrapped lines
- [ ] Alternate-screen/TUI app (for example `vim`, `top`, or `htop`) renders and exits cleanly
- [ ] Terminal remains responsive after leaving alternate-screen apps
- [ ] IME caret placement is correct while composing CJK text
- [ ] CJK text entry inserts the expected characters without duplicated or dropped input

## Multi-session Isolation
- [ ] Open at least 3 concurrent sessions
- [ ] Commands in session A do not appear in session B/C
- [ ] Switching tabs keeps each session transcript intact
- [ ] Splitting panes keeps session input/output isolated
- [ ] Returning to a previously active pane restores focus and input correctly

## File Manager Session Binding
- [ ] Keep File Manager expanded, open same SSH host in a second session, and verify no `SSH client is not connected` error
- [ ] Slow-connection second-session path still binds File Manager to the new session
- [ ] Switching between two active SSH sessions does not leak stale File Manager error overlays
- [ ] Returning to a previously opened SSH session restores its remote directory state

## SFTP Navigation And CRUD
- [ ] Host A file listing loads successfully
- [ ] Host B file listing loads successfully
- [ ] Navigate into a child directory and back
- [ ] Create file, create directory, rename, move, copy, and delete all succeed
- [ ] Remote file properties load correctly
- [ ] Remote text file open/edit/save round-trip succeeds
- [ ] Behavior is consistent across both server distributions

## Transfers, Drag/Drop, And Feedback
- [ ] Upload to the current directory succeeds
- [ ] Drag/drop onto a directory uses that directory as the target
- [ ] Drag/drop onto empty area falls back to the current directory
- [ ] Download succeeds and surfaces the saved path clearly
- [ ] Conflict handling (`skip` / `replace` / `rename`) behaves as expected
- [ ] Failed transfer can be retried successfully
- [ ] Toast/status feedback appears for upload, download, rename, move, delete, and retry
- [ ] Transfer progress remains believable for multi-file operations

## Stability
- [ ] Run 20+ commands continuously without transcript disappearing
- [ ] Trigger at least one network interruption and verify failure message
- [ ] Reconnect after interruption and verify normal command execution
- [ ] Long-running session does not leak stale loading/error UI in terminal or file manager

## Security Baseline
- [ ] Private key path works without exposing key content in logs
- [ ] No plaintext credential appears in UI/log output
- [ ] Host key behavior follows expected policy (`accept-new` + changed-key failure)

## Result Summary
- [ ] Acceptance result recorded: `PASS` or `FAIL`
- [ ] If failed, issue list recorded with reproduction steps
