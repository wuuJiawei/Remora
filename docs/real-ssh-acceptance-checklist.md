# Real SSH Acceptance Checklist

Use this checklist for manual acceptance on at least two real SSH hosts (for example one LAN host and one public host).

## Environment
- [ ] macOS version recorded
- [ ] Remora commit hash recorded
- [ ] Host A/B connection metadata prepared (host, port, username, auth method)
- [ ] Accessibility permission enabled (for optional UI automation run)

## Connection & Authentication
- [ ] Host A connects successfully
- [ ] Host B connects successfully
- [ ] Wrong username/password/key shows explicit failure state
- [ ] Unreachable host shows explicit failure state
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

## Multi-session Isolation
- [ ] Open at least 3 concurrent sessions
- [ ] Commands in session A do not appear in session B/C
- [ ] Switching tabs keeps each session transcript intact

## File Manager Session Binding
- [ ] Keep File Manager expanded, open same SSH host in a second session, and verify no `SSH client is not connected` error
- [ ] Slow-connection second-session path still binds File Manager to the new session
- [ ] Switching between two active SSH sessions does not leak stale File Manager error overlays
- [ ] Returning to a previously opened SSH session restores its remote directory state

## Stability
- [ ] Run 20+ commands continuously without transcript disappearing
- [ ] Trigger at least one network interruption and verify failure message
- [ ] Reconnect after interruption and verify normal command execution

## Security Baseline
- [ ] Private key path works without exposing key content in logs
- [ ] No plaintext credential appears in UI/log output
- [ ] Host key behavior follows expected policy (`accept-new` + changed-key failure)

## Result Summary
- [ ] Acceptance result recorded: `PASS` or `FAIL`
- [ ] If failed, issue list recorded with reproduction steps
