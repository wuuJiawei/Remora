# Native SSH Session Execution Plan

**Architecture:** `docs/plans/2026-07-22-native-ssh-session-architecture.md`  
**Start point:** `main` at `deed85e8d8cec8b3208b2cd79dd3d2875bbb2677`  
**Worktree:** `.worktree/native-ssh-session`  
**Branch:** `codex/native-ssh-session`  

## 1. Execution rules

This migration is incremental in delivery but not indefinite in architecture.

- Every phase has an entry condition, bounded scope, tests, exit condition, and rollback
  boundary.
- A compatibility adapter is allowed only when it lets one consumer move to the final
  API. It must have an owner and deletion phase in this plan.
- No `catch { fallbackToOpenSSH() }` behavior is allowed.
- No terminal-output parsing is added for target identity or authentication.
- No side-effect command is automatically replayed.
- Transport work stays off the main actor.
- New user-visible strings use `tr(...)` and update both localization files.
- Third-party code is isolated and carries license, source revision, checksum, and
  update instructions.
- Each phase is committed separately with an imperative commit message.
- A phase does not start if the previous phase's exit gate is red.

## 2. Change inventory

### 2.1 Keep and evolve

| Existing area | Action |
|---|---|
| `Host`, `HostAuth`, `HostPolicies` | Keep persisted compatibility; add versioned route/provider configuration |
| `CredentialStore` | Keep Keychain ownership; expose typed secret requests to auth coordinator |
| `HostKeyStore` | Evolve to endpoint/algorithm/key-aware records and atomic known-host decisions |
| `TerminalRuntime` | Keep UI/runtime coordination; replace host/process session binding with session lease and shell channel |
| `SessionManagerProtocol` | Replace terminal-only manager semantics with a shell-facing adapter over `RemoteSessionHub`, then remove adapter if unused |
| `FileTransferViewModel` | Keep workflow/state; replace `SFTPClientProtocol` dependency with `RemoteFileSystem` and command executor |
| Docker parsing/models/UI | Keep; inject command executor and improve typed errors |
| Metrics parsing/models/UI | Keep; inject command executor and remove per-host client cache |
| ZModem/OSC/CWD logic | Keep byte-stream integration; adapt to native shell channel |
| AppKit file/Docker windows | Keep UI; own and release leases explicitly |

### 2.2 Rewrite behind final APIs

| Existing implementation | Replacement |
|---|---|
| OpenSSH process shell | Native libssh2 shell channel |
| System SFTP process/fallbacks | Native subsystem SFTP + administrator SFTP wire client |
| Remote command via SFTP client | `RemoteCommandExecutor` |
| OpenSSH port-forward process | `NWListener` + libssh2 direct-tcpip channel |
| Prompt sniffing for auth | Typed libssh2 authentication challenge flow |
| Runtime saved-host binding | `RemoteSessionIdentitySnapshot` |

### 2.3 Delete by final phase

- `Sources/RemoraCore/SSH/SystemSSHClient.swift`
- `Sources/RemoraCore/SFTP/SystemSFTPClient.swift`
- `Sources/RemoraCore/SSH/OpenSSHLaunchBuilder.swift`
- `Sources/RemoraCore/SSH/SSHConnectionReuse.swift`
- `Sources/RemoraCore/SSH/SSHControlMasterCleanup.swift`
- `Sources/RemoraCore/SSH/OpenSSHPortForwardClient.swift`
- ASKPASS/sshpass scripts and tests used only by process transport.
- Shell-command requirements/defaults in `SFTPClientProtocol`.
- Purpose-split ControlMaster tests and compatibility behavior.
- Empty-semantics `requireExistingSSHConnection` branching.

Deletion is deferred until all named consumers are migrated, but no new feature may
depend on these files after Phase 2.

## 3. Phase map

| Phase | Deliverable | Risk | Rollback boundary |
|---|---|---:|---|
| 0 | Architecture, inventory, dependency decision | Low | Documentation commit |
| 1 | `RemoraSSHNative` boundary and final Swift protocols/state | Medium | New isolated targets/files only |
| 2 | Native direct-host transport, host key, auth, shell | High | Developer transport selection at composition root |
| 3 | Session hub, leases, terminal migration | High | Revert composition to process shell before merge gate |
| 4 | Command executor, Docker, metrics, archive migration | High | Consumer-level adapter removal/revert |
| 5 | Normal SFTP and file workflows | High | File consumer remains on old implementation until gate |
| 6 | Administrator SFTP v3 wire engine | High | Admin mode unavailable rather than shell fallback |
| 7 | JumpServer provider and route UX | High | Direct routes remain stable; provider config is additive |
| 8 | Native local forwarding and remaining integrations | Medium | Forward-specific revert |
| 9 | Delete OpenSSH/SystemSFTP/ControlMaster and migration switches | High | One deletion commit can be reverted before release |
| 10 | Cross-architecture packaging, soak, docs, release readiness | Medium | No release until all gates pass |

## 4. Phase 0: Architecture and dependency gate

### Entry condition

- Root cause reproduced or supported by code evidence.
- `main` baseline recorded.
- Worktree created inside `.worktree/`.

### Tasks

- [x] Inventory terminal, Docker, files, transfers, remote editor/log, archive,
  metrics, forwarding, CWD sync, ZModem, auth, host key, errors, logs, and tests.
- [x] Record target architecture and explicit non-goals.
- [x] Verify JumpServer Koko direct-login identity format.
- [x] Verify `libssh2` has keyboard-interactive, host-key, agent, shell, exec, SFTP,
  and channel APIs.
- [x] Verify `libssh2_sftp_init` cannot attach to an arbitrary sudo exec channel.
- [x] Select the exact reviewed libssh2 release/commit, not an unreviewed moving HEAD.
- [x] Select and pin a crypto backend that can be statically distributed on macOS.
- [x] Add third-party license notices and a documented update process.
- [x] Prove reproducible arm64 and x86_64 builds without Homebrew.

### Dependency packaging decision gate

Preferred repository layout:

```text
Vendor/RemoraSSHNative/
  Package.swift
  Sources/RemoraSSHNative/include/remora_ssh.h
  Sources/RemoraSSHNative/remora_ssh.c
  Vendor/libssh2/...
  Vendor/<crypto-backend>/...
  LICENSES/...
  UPSTREAM.md
```

The native package may vendor audited sources or consume a pinned, reproducibly built
static artifact. It may not load `/opt/homebrew` or `/usr/local` dylibs in production.
The choice is accepted only after both release architectures pass link and package
inspection (`otool -L` contains no Homebrew paths).

### Exit condition

- Architecture document accepted.
- Native dependency selection has a recorded revision/checksum/license.
- A minimal native fixture builds in SwiftPM and generated Xcode project for both
  release architectures.

### Rollback

Revert Phase 0/1 files. No runtime behavior has changed.

## 5. Phase 1: Native boundary and final protocol skeleton

### Entry condition

- Phase 0 architecture accepted.

### Files to add

```text
Sources/RemoraCore/RemoteSession/RemoteTargetIdentity.swift
Sources/RemoraCore/RemoteSession/ConnectionRoute.swift
Sources/RemoraCore/RemoteSession/RemoteSessionState.swift
Sources/RemoraCore/RemoteSession/RemoteSessionError.swift
Sources/RemoraCore/RemoteSession/RemoteSessionProtocols.swift
Sources/RemoraCore/RemoteCommand/RemoteCommandModels.swift
Sources/RemoraCore/RemoteCommand/RemoteCommandExecutor.swift
Sources/RemoraCore/RemoteFileSystem/RemoteFileSystem.swift
Sources/RemoraCore/RemoteFileSystem/RemoteFileSystemModels.swift
Tests/RemoraCoreTests/RemoteSessionModelTests.swift
Tests/RemoraCoreTests/RemoteCommandModelTests.swift
Tests/RemoraCoreTests/RemoteFileSystemContractTests.swift
```

Native package files are added according to the dependency gate.

### Tasks

- [x] Define stable route and runtime target identity values.
- [x] Define session states and legal transitions.
- [x] Define typed errors with safe diagnostic metadata.
- [x] Define shell, exec, file, and forwarding capabilities without implementation
  defaults that hide unsupported behavior.
- [x] Define `RemoteCommandRequest`, result/stream events, privilege, timeout, and replay
  policy.
- [x] Define streaming file handles and metadata; avoid `Data`-only transfer contracts.
- [x] Add native opaque handle creation/destruction smoke tests.
- [x] Add failure-path tests proving double-close and use-after-close are rejected.
- [x] Update `Package.swift` and `scripts/generate_xcodeproj.rb` from the same source of
  truth so SwiftPM and packaged Xcode builds remain aligned.

### Design checks

- `RemoteFileSystem` has no command method.
- `RemoteCommandExecutor` has no file listing/copy convenience method.
- Runtime identities are `Hashable` and do not depend on display strings.
- No public protocol returns raw libssh2 pointers.
- No operation requires `@MainActor`.
- Cancellation and timeout are explicit on long-running operations.

### Verification

- `swift build`
- `swift test --filter RemoteSessionModelTests`
- `swift test --filter RemoteCommandModelTests`
- `swift test --filter RemoteFileSystemContractTests`
- Native fixture tests with Address Sanitizer where supported.
- Generated Xcode project builds the native target.

### Exit condition

- Final capability boundaries compile and have contract tests.
- Native handles can be created/destroyed in both architectures.
- No existing runtime consumer has changed behavior.

### Commit

`Define native SSH session boundaries`

## 6. Phase 2: Native direct-host transport

### Entry condition

- Phase 1 green in SwiftPM and generated Xcode builds.

### Files to add/evolve

```text
Sources/RemoraCore/RemoteSession/LibSSH2Transport.swift
Sources/RemoraCore/RemoteSession/SocketReadiness.swift
Sources/RemoraCore/RemoteSession/AuthenticationCoordinator.swift
Sources/RemoraCore/RemoteSession/HostKeyVerifier.swift
Sources/RemoraCore/RemoteSession/NativeShellChannel.swift
Sources/RemoraCore/Security/HostKeyStore.swift
Tests/RemoraCoreTests/LibSSH2TransportTests.swift
Tests/RemoraCoreTests/AuthenticationCoordinatorTests.swift
Tests/RemoraCoreTests/NativeHostKeyTests.swift
Tests/RemoraCoreTests/NativeShellChannelTests.swift
```

### Tasks

- [x] Implement TCP connect with DNS/connect timeout and cancellation.
- [x] Implement nonblocking handshake and socket-readiness waiting.
- [x] Fetch advertised authentication methods.
- [x] Implement agent, private-key, passphrase, password, and keyboard-interactive auth.
- [x] Support multi-round/multi-prompt keyboard-interactive challenges.
- [x] Implement cancellation that wakes challenge and socket waits.
- [x] Implement host-key SHA-256 fingerprinting, unknown-key trust, and mismatch block.
- [x] Persist host-key decisions atomically.
- [x] Implement PTY shell open, stdout/stderr, stdin, resize, EOF, exit status, close.
- [x] Add bounded diagnostic events for every state transition.

### Implementation verification status

- `swift build` passes.
- The generated Xcode project builds the complete Release app for arm64 and x86_64.
- Both app executables contain the native shim, libssh2, and mbedTLS symbols and have no
  Homebrew or other non-system dynamic-library dependency.
- Real SSH fixtures, authentication flows, sanitizers, and runtime behavior were not
  executed at the user's request. The Phase 2 exit condition therefore remains pending
  user acceptance and must not be treated as green solely from compile verification.

### Test fixtures

Use disposable local SSH fixtures; never depend on a developer's `~/.ssh` state.

- Direct key auth.
- Agent auth.
- Password auth.
- Keyboard-interactive one round.
- Keyboard-interactive two rounds (password then OTP).
- Encrypted private key/passphrase.
- Unknown host key accept/reject.
- Changed host key hard failure.
- Slow handshake timeout and cancellation.
- Server closes during auth and during active shell.
- Shell output flood plus rapid input/resize.

### Exit condition

- A test harness opens a real native direct-host shell for all supported auth methods.
- No auth path parses terminal output.
- All libssh2 calls are serialized and off-main-thread.
- Memory/thread sanitizer runs show no native lifetime defects in the fixture suite.

### Commit

`Implement native direct SSH transport`

## 7. Phase 3: Session hub, leases, and terminal migration

### Entry condition

- Native direct-host shell passes Phase 2.

### Files to add/evolve

```text
Sources/RemoraCore/RemoteSession/RemoteSession.swift
Sources/RemoraCore/RemoteSession/RemoteSessionHub.swift
Sources/RemoraCore/RemoteSession/RemoteSessionLease.swift
Sources/RemoraCore/Session/SessionManager.swift
Sources/RemoraCore/Protocols/SessionManagerProtocol.swift
Sources/RemoraApp/TerminalRuntime.swift
Sources/RemoraApp/RemoraAppMain.swift
Tests/RemoraCoreTests/RemoteSessionHubTests.swift
Tests/RemoraAppTests/TerminalRuntimeTests.swift
Tests/RemoraAppTests/WorkspaceViewModelTests.swift
```

### Tasks

- [x] Implement acquire deduplication for concurrent identical session keys.
- [x] Implement explicit lease release and last-lease close.
- [x] Implement channel registry and shutdown ordering.
- [x] Expose immutable identity/state snapshots to app code.
- [x] Adapt `SessionManager` to obtain shell channels from the hub.
- [x] Replace terminal runtime `connectedSSHHost` binding with session identity while
  keeping a saved-host reference only for catalog/reconnect configuration.
- [x] Preserve terminal output, input, resize, OSC/CWD, clone/split, and ZModem behavior.
- [x] Remove OpenSSH prompt detection from native terminal path.
- [x] Add one developer-only composition switch for differential testing; do not add a
  runtime fallback.

The composition seam is constructor injection on `TerminalRuntime`; production defaults
to the native manager, while focused fixtures can inject the process-backed test manager.
There is no error-triggered runtime fallback.

### Implementation verification status

- Shared-session lifecycle, terminal adapter, typed authentication interaction, and
  default native composition compile in SwiftPM.
- Real direct-host shell, split/clone, CWD, ZModem, cancellation, and lifecycle counter
  behavior were not executed at the user's request. Phase 3 runtime exit conditions
  remain pending user acceptance.

### Lifecycle test matrix

- Two concurrent acquires produce one transport and two leases.
- Terminal split opens independent shell channels on one session.
- Closing one split closes one channel only.
- Terminal closes while file/Docker placeholder lease remains: session stays ready.
- Last release closes all channels then transport exactly once.
- Auth cancellation leaves no hub entry.
- Reconnect replaces transport without reusing closed native handles.
- Workspace clone copies configuration, not a lease object accidentally.

### Performance verification

- Run terminal stress tool through native shell.
- Measure input/output latency with an active synthetic file-stream channel.
- Confirm no main-thread checker violations.
- Confirm channel output buffering stays bounded during hidden/minimized windows.

### Exit condition

- Direct-host terminal uses native transport by default in development builds.
- Existing terminal-focused tests pass or are replaced by stronger native tests.
- Split/clone/CWD/ZModem behaviors are verified.
- Session/lease lifecycle counters return to zero after close.

### Commit

`Migrate terminal runtime to shared SSH sessions`

## 8. Phase 4: Exec channel, Docker, metrics, and remote tools

### Entry condition

- Terminal owns a native session and exposes lease acquisition to independent windows.

### Files to add/evolve

```text
Sources/RemoraCore/RemoteCommand/LibSSH2CommandExecutor.swift
Sources/RemoraApp/DockerCommandService.swift
Sources/RemoraApp/DockerPanelViewModel.swift
Sources/RemoraApp/DockerWorkspaceWindow.swift
Sources/RemoraApp/ServerMetricsCenter.swift
Sources/RemoraApp/FileTransferViewModel.swift
Sources/RemoraApp/FileManagerWorkspaceWindow.swift
Sources/RemoraApp/RemoteArchiveSupport.swift
Sources/RemoraApp/QuickCommandExecution.swift
Sources/RemoraApp/ExtensionScriptRunnerViewModel.swift
Tests/RemoraCoreTests/RemoteCommandExecutorTests.swift
Tests/RemoraAppTests/DockerCommandServiceTests.swift
Tests/RemoraAppTests/ServerMetricsPanelTests.swift
Tests/RemoraAppTests/RemoteArchiveSupportTests.swift
```

### Tasks

- [x] Implement exec channel stdout/stderr separation, stdin, exit status, timeout,
  cancellation, and bounded output collection.
- [x] Centralize audited POSIX argument quoting.
- [x] Implement privilege wrapper as request metadata; use `sudo -n` only.
- [x] Require replay policy for every request builder.
- [x] Inject a session-scoped executor into Docker; remove SFTP construction.
- [x] Preserve Docker command parsing but classify executable/daemon/permission/parse
  failures separately.
- [x] Inject executor into metrics and delete per-host `SystemSFTPClient` cache.
- [x] Mark metrics, archive inspection, and remote search `.readOnly`; mark Docker
  mutations, archive mutations/install, and log follow `.never`.
- [x] Keep quick commands on the current interactive native shell. They are terminal
  input, not background exec requests, so replay policy does not apply.
- [x] Confirm extension scripts are intentionally local plugin processes that receive
  host metadata. They do not execute through SSH and require no remote-command migration.
- [x] Make Docker window hold its own session lease and release it on close.
- [x] Make file-window remote tools use a session-scoped executor and an independent
  lease; keep file I/O on the Phase 5 SFTP boundary until it is replaced atomically.

### Implementation status

- The native shim and Swift transport now expose nonblocking exec channels with
  separate stdout/stderr, stdin EOF, timeout, cancellation, exit status, and bounded
  collection.
- Docker read and mutation paths, including live logs, use a session-scoped executor.
  The Docker window owns an independent lease, so terminal closure does not release the
  Docker session.
- Metrics are keyed by native session identity, use a retained lease/executor, and no
  longer create per-host `SystemSFTPClient` instances. Password-authenticated sessions
  are no longer excluded.
- Archive, archive capability/install, remote search, log tail, and log follow paths use
  the file window's native command executor. No RemoraApp consumer calls the shell-command
  methods on `SFTPClientProtocol`.
- Quick commands retain interactive terminal semantics, and extension scripts retain
  their documented local-plugin semantics; neither is misclassified as remote exec.
- `swift build` and static command-consumer searches pass. Runtime regression tests,
  real-server validation, and disconnect-before-output retry remain pending, so the
  Phase 4 runtime exit gate is not green.

### Required regression tests

- Docker and terminal commands operate concurrently on one transport.
- JumpServer is still intentionally unavailable until Phase 7; route error is explicit.
- `docker: command not found` differs from daemon unavailable and socket permission.
- MFA/auth errors cannot be transformed into Docker permission messages.
- Timeout closes only the exec channel.
- Disconnect before command output retries metrics once but never retries Docker mutate.
- Sudo noninteractive failure maps to privilege-required.

### Exit condition

- Docker, metrics, archive, remote search, and remote log paths no longer call command
  methods on `SFTPClientProtocol`.
- No consumer constructs `SystemSFTPClient` for command execution. The file window still
  constructs it only for Phase 5 file I/O until native SFTP replaces that binding.
- Docker and terminal remain usable after either independent window closes.

### Commit

`Move remote commands onto shared SSH sessions`

## 9. Phase 5: Normal SFTP and file workflows

### Entry condition

- Shared session and native exec are stable.

### Files to add/evolve

```text
Sources/RemoraCore/RemoteFileSystem/LibSSH2RemoteFileSystem.swift
Sources/RemoraCore/RemoteFileSystem/RemoteFileHandle.swift
Sources/RemoraApp/FileManagerWorkspaceWindow.swift
Sources/RemoraApp/FileTransferViewModel.swift
Sources/RemoraApp/TransferCenter.swift
Sources/RemoraApp/RemoteTextEditorViewModel.swift
Sources/RemoraApp/RemoteLogViewerViewModel.swift
Sources/RemoraApp/RemoteFilePropertiesViewModel.swift
Sources/RemoraApp/RemotePermissionsEditorViewModel.swift
Tests/RemoraCoreTests/LibSSH2RemoteFileSystemTests.swift
Tests/RemoraAppTests/FileTransferViewModelTests.swift
Tests/RemoraAppTests/MockRemoteFileSystem.swift
Tests/RemoraAppTests/MockRemoteCommandExecutor.swift
Tests/RemoraAppTests/TransferCenterTests.swift
```

### Tasks

- [x] Map SFTP v3 status/attributes to final filesystem models.
- [x] Implement native list/stat/read/write/rename/mkdir/remove/set-attributes and
  symbolic-link primitives behind `RemoteFileSystem`.
- [x] Bound native file-handle reads/writes to 64 KiB and return partial-write counts
  for caller-driven backpressure.
- [x] Define symlink behavior and avoid following links during recursive delete/copy
  unless explicitly requested.
- [x] Use temporary upload path plus rename for workflows that promise atomic save.
- [x] Inject `RemoteFileSystem` into file window/view model.
- [x] Make the file window own a lease independent from terminal and Docker.
- [x] Keep last successful directory snapshot when refresh fails; show typed error.
- [x] Migrate editor, log viewer, properties, permissions, archive directory picker,
  transfers, drag/drop, and directory sync.
- [x] Remove full-memory transfer defaults from production transfer paths.
- [x] Migrate focused App test fixtures from `SFTPClientProtocol` to reusable native
  filesystem and command executor doubles.

### Partial implementation status

- Native ABI v3 exposes opaque SFTP subsystem and file/directory handles without leaking
  libssh2 pointers into Swift APIs.
- SFTP status codes map to typed filesystem errors, and attribute updates deliberately do
  not send the display-only file size as `SETSTAT`, avoiding accidental truncation.
- `LibSSH2RemoteFileSystem` serializes all libssh2 calls through the transport executor,
  uses socket-readiness waits for nonblocking operations, and closes file handles before
  the SFTP subsystem and transport.
- `RemoteFileSystemOperations` owns symlink-safe recursion, 64 KiB streaming, partial-write
  backpressure, per-partial-write upload progress, and same-directory temporary-file
  replacement for upload/copy workflows.
- The file window acquires one independent lease and obtains its command executor and native
  filesystem from the same `RemoteSession`. Closing the terminal tab no longer rebinds the
  file window to a disconnected client; closing the file window closes only its filesystem
  and releases only its own lease.
- `FileTransferViewModel` and all file-window consumers use the native filesystem boundary.
  Normal file mode no longer references `SystemSFTPClient`, `DisconnectedSFTPClient`, or
  `SFTPClientProtocol`.
- Administrator file mode is explicitly unavailable until Phase 6 instead of falling back to
  shell/OpenSSH behavior. Normal file mode can be resumed without replacing the native lease.
- Directory refresh preserves the last successful snapshot and surfaces localized typed SFTP
  errors in the native empty state and toast while retaining detailed file logs.
- Focused App test fixtures now inject reusable `MockRemoteFileSystem` and
  `MockRemoteCommandExecutor` doubles. App tests no longer reference `SFTPClientProtocol`,
  `MockSFTPClient`, or the removed SFTP binding API.
- `swift build` and `swift build --build-tests` pass, so production and test targets compile
  and link. Tests were not executed; focused behavior checks and real direct/JumpServer SFTP
  validation remain pending because the user owns runtime verification.

### Filesystem test matrix

- Empty/non-empty directories, UTF-8 names, spaces, quotes, newlines, long names.
- Files greater than available memory via streaming fixture.
- Cancellation at open, mid-read/write, fsync/finalize, and rename.
- Permission denied and not found remain distinct.
- Symlink to file/directory and symlink cycles.
- Rename across directories and server unsupported-extension behavior.
- Disconnect mid-download and mid-upload; no blind side-effect replay.
- Concurrent terminal output plus two file transfers.
- Window close cancels its work but does not disconnect other leases.

### Exit condition

- Normal file mode no longer constructs or references `SystemSFTPClient`.
- File manager displays errors instead of false empty states.
- Remote editor/log/properties/permissions and transfers pass their focused tests.
- Transfer memory remains inside the declared budget.

### Commit

`Migrate file workflows to native SFTP`

## 10. Phase 6: Administrator SFTP wire engine

### Entry condition

- Normal native SFTP contract is stable.
- RemoteFileSystem contract tests can be reused against a second implementation.

### Files to add/evolve

```text
Sources/RemoraCore/RemoteFileSystem/SFTPWire/SFTPPacket.swift
Sources/RemoraCore/RemoteFileSystem/SFTPWire/SFTPCodec.swift
Sources/RemoraCore/RemoteFileSystem/SFTPWire/SFTPRequestMultiplexer.swift
Sources/RemoraCore/RemoteFileSystem/SFTPWire/ExecSFTPRemoteFileSystem.swift
Sources/RemoraCore/RemoteFileSystem/AdministratorSFTPServerResolver.swift
Tests/RemoraCoreTests/SFTPCodecTests.swift
Tests/RemoraCoreTests/SFTPRequestMultiplexerTests.swift
Tests/RemoraCoreTests/ExecSFTPRemoteFileSystemTests.swift
```

### Tasks

- [x] Implement packet framing with maximum packet length before allocation.
- [x] Implement v3 INIT/VERSION, request IDs, STATUS, HANDLE, DATA, NAME, ATTRS, and
  required mutation packets.
- [x] Parse attributes with overflow and truncation checks.
- [x] Cap outstanding requests and reorder responses by request ID.
- [x] Discover `sftp-server` only from absolute allowlisted/configured paths.
- [x] Start `sudo -n -- <path>` without a shell when possible.
- [x] Validate initial VERSION before exposing filesystem capability.
- [ ] Run the same RemoteFileSystem contract suite as normal SFTP.
- [x] Connect administrator toggle to filesystem capability replacement, not a new SSH
  connection.
- [x] Localize privilege-required and unsupported-server messages.

### Implementation verification status

- The wire codec enforces a 1 MiB packet limit from the four-byte header, bounds strings,
  NAME entries, and extended attributes, and rejects truncated data at end of stream.
- The request multiplexer caps in-flight work at 64, matches out-of-order responses by ID,
  rejects unknown/duplicate IDs, and safely discards one late response for a cancelled request.
- Administrator mode resolves only normalized absolute allowlisted server paths, starts one
  long-lived `sudo -n -- <path>` exec channel, and validates SFTP v3 before registration.
- Normal and administrator filesystems are owned by the same session lease. Switching modes
  preserves independent directory/cache state and closes the administrator channel when normal
  mode resumes.
- Codec, multiplexer, resolver, exec-filesystem, and App toggle contract tests compile with
  `swift build --build-tests`. Tests and real direct-host/JumpServer validation were not run at
  the user's request, so the shared contract-suite exit item remains open for user acceptance.

### Security/fuzz verification

- Truncated length/type/request ID/attributes.
- Declared packet length above cap.
- Duplicate and unknown request IDs.
- Unexpected STATUS for each request.
- Channel stderr before VERSION (sudo failure).
- EOF with incomplete frame.
- Malicious filenames and attribute counts.
- Fuzz codec with deterministic seed corpus and sanitizer build.

### Exit condition

- Administrator mode uses the same transport via exec channel.
- No filesystem operation parses `ls`, `stat`, `cp`, `mv`, `rm`, or shell locale text.
- `sudo -n` failure is explicit and does not trigger password automation/fallback.
- Normal and administrator implementations pass the shared contract suite.

### Commit

`Add administrator SFTP over exec channels`

## 11. Phase 7: JumpServer provider and explicit target routes

### Entry condition

- Shell, exec, and both file modes work on direct routes through one session.

### Files to add/evolve

```text
Sources/RemoraCore/Gateway/GatewayProvider.swift
Sources/RemoraCore/Gateway/JumpServerGatewayProvider.swift
Sources/RemoraCore/Models/Host.swift
Sources/RemoraApp/HostCatalog.swift
Sources/RemoraApp/HostConnectionImporter.swift
Sources/RemoraApp/HostConnectionExporter.swift
Sources/RemoraApp/<connection-editor-files>
Sources/RemoraApp/Resources/en.lproj/Localizable.strings
Sources/RemoraApp/Resources/zh-Hans.lproj/Localizable.strings
Tests/RemoraCoreTests/JumpServerGatewayProviderTests.swift
Tests/RemoraAppTests/HostCatalogPersistenceStoreTests.swift
Tests/RemoraAppTests/HostConnectionImporterTests.swift
Tests/RemoraAppTests/HostConnectionExporterTests.swift
```

### Tasks

- [ ] Add versioned direct/gateway route persistence without guessing existing hosts.
- [ ] Define provider protocol and canonical target identity.
- [ ] Implement JumpServer direct-login username generation and validation.
- [ ] Require platform username, protocol, asset, and asset account before connect.
- [ ] Add connection editor route/provider fields with native macOS controls.
- [ ] Store secrets/tokens only as Keychain references.
- [ ] Add optional provider asset lookup only if API authentication is explicitly
  configured; do not scrape the interactive menu.
- [ ] Represent manual interactive gateway sessions as unbound target sessions.
- [ ] Disable dependent panels for unbound targets with a typed/localized reason.
- [ ] Ensure shell, Docker, metrics, normal files, and admin files use the same canonical
  target identity and leaseable session.

### JumpServer matrix

- Password plus OTP keyboard-interactive.
- Password plus email code in a second round.
- Multiple prompts in one round with echo flags.
- Cancel at each auth round.
- Wrong OTP followed by server retry.
- Asset not found/account unauthorized/protocol unsupported.
- Direct-login delimiter and escaping validation.
- Target shell opens, then Docker and files open without another MFA prompt.
- Close terminal; Docker and files continue.
- Close Docker; file transfer continues.
- Reconnect after gateway disconnect; side effects are not replayed.
- Manual menu session gives target-unresolved state, never empty panels.

### Exit condition

- The reported JumpServer workflow works end to end with one transport and explicit
  target identity.
- No prompt/title/transcript parsing identifies the asset.
- Windows are independently usable and independently closable.
- Direct-host persistence/import/export remains backward compatible.

### Commit

`Add explicit JumpServer target sessions`

## 12. Phase 8: Forwarding and remaining integrations

### Entry condition

- Route/provider session behavior is stable.

### Tasks

- [ ] Replace OpenSSH local forwarding with `NWListener` and direct-tcpip channels.
- [ ] Give every active forward a session lease.
- [ ] Add bounded bidirectional pumps and half-close handling.
- [ ] Verify forwarding through direct and JumpServer routes.
- [ ] Search the full repository for remaining transport construction and remote command
  use.
- [ ] Migrate any remaining shell integration installer or helper that launches
  independent SSH.

### Verification

- Multiple local clients on one forward.
- Backpressure with slow local/remote peer.
- Local port conflict and listener cancellation.
- Session disconnect/reconnect behavior is explicit.
- Last forward close releases its lease.

### Exit condition

Repository search finds no production consumer creating OpenSSH/SystemSFTP transports.

### Commit

`Move port forwarding onto shared SSH sessions`

## 13. Phase 9: Delete legacy transport and compatibility debt

### Entry condition

- All consumers have passed native-path gates.
- Differential metrics show no unresolved blocker.

### Tasks

- [ ] Delete files listed in Section 2.3.
- [ ] Delete process-transport factories and developer transport switch.
- [ ] Delete ControlMaster purpose/retry/cache tests.
- [ ] Delete OpenSSH prompt/auth sniffing and compatibility profile code that no longer
  maps to native negotiation.
- [ ] Delete command methods and unsupported defaults from `SFTPClientProtocol`.
- [ ] Rename the final file protocol to `RemoteFileSystem` everywhere and remove old
  protocol aliases.
- [ ] Delete disconnected clients that represent errors as empty success; replace with
  explicit unavailable state.
- [ ] Remove obsolete logs, localization keys, settings, and docs.
- [ ] Run dead-code search and repository-wide reference search.

### Required zero-reference checks

```bash
rg -n "SystemSSHClient|OpenSSHProcessClient|ProcessSSHShellSession" Sources Tests
rg -n "SystemSFTPClient|executeRemoteShellCommand|streamRemoteShellCommand" Sources Tests
rg -n "ControlMaster|ControlPath|sshpass|SSH_ASKPASS" Sources Tests
rg -n "OpenSSHPortForwardProcess|requireExistingSSHConnection" Sources Tests
```

All commands must return no production references. Test fixture strings are allowed only
when testing migration/import behavior and must be explained inline.

### Exit condition

- No production OpenSSH process fallback remains.
- No purpose-split connection reuse remains.
- No file API owns command execution.
- Full build/test/package gates pass.

### Commit

`Remove legacy OpenSSH transport paths`

## 14. Phase 10: Release readiness

### Build matrix

- `swift build` on macOS 14+.
- `swift test`.
- Generated Xcode project Debug/Release.
- arm64 archive/package.
- x86_64 archive/package.
- `otool -L` verification for app and embedded libraries.
- Codesign verification after packaging.
- Clean-machine launch without Homebrew.

### Functional matrix

| Route | Auth | Terminal | Docker | Files | Admin files | Metrics | Forward |
|---|---|---:|---:|---:|---:|---:|---:|
| Direct | Agent | Required | Required | Required | Required | Required | Required |
| Direct | Key | Required | Required | Required | Required | Required | Required |
| Direct | Encrypted key | Required | Required | Required | Required | Required | Required |
| Direct | Password | Required | Required | Required | Required | Required | Required |
| Direct | Keyboard-interactive | Required | Required | Required | Required | Required | Required |
| JumpServer | Password + MFA | Required | Required | Required | Required | Required | Required |

### Soak scenarios

- Eight-hour terminal session with metrics sampling and periodic directory refresh.
- Large upload/download while continuously typing and resizing terminal.
- Repeatedly open/close Docker and file windows; verify native handle/socket counts.
- Network flap during each operation class.
- Sleep/wake with active session and forward.
- 100 connect/cancel cycles at host-key and MFA dialogs.
- Memory graph confirms no session/lease/window retain cycles.

### Documentation

- Update architecture/user docs and changelog.
- Document explicit JumpServer target configuration.
- Document `sudo -n` requirement for administrator file mode.
- Record third-party dependency versions/licenses and update procedure.
- Add safe diagnostic instructions and log field meanings.

### Final exit condition

- All architecture acceptance invariants pass.
- No P0/P1 correctness, security, data-loss, hang, or lifecycle defect remains.
- Performance budgets pass under transfer load.
- Both release architectures package and launch on clean machines.
- The old transport is deleted, not hidden behind a fallback.

## 15. Risk register

| Risk | Likelihood | Impact | Control |
|---|---:|---:|---|
| Native handle lifetime/use-after-free | Medium | Critical | Opaque ownership, actor serialization, sanitizer tests, exact close ordering |
| Keyboard-interactive callback deadlock | Medium | High | Dedicated executor, bounded challenge bridge, cancellation wakeup, stress tests |
| Main-thread blocking | Medium | High | No `@MainActor` transport APIs, signposts, Main Thread Checker |
| SFTP wire malformed packet allocation | Medium | Critical | Length caps before allocation, fuzzing, request caps |
| Ambiguous command replay duplicates mutation | Medium | Critical | `.never` default, output-aware retry gate, tests |
| Host-key regression permits MITM | Low | Critical | Verify before auth, mismatch hard block, typed destructive replacement |
| Third-party static package fails one architecture | Medium | High | Dependency phase gate before runtime migration |
| JumpServer direct-login format varies by deployment | Medium | High | Provider validation/configuration, typed unsupported route, no guessing |
| Server lacks `sftp-server` path or passwordless sudo | High | Medium | Allowlisted discovery/config override, explicit unsupported/privilege state |
| Transfer starves terminal | Medium | High | Chunking, fairness scheduling, buffer budgets, stress thresholds |
| Lease leak keeps sockets alive | Medium | Medium | Explicit release, registry diagnostics, lifecycle tests, soak counters |
| Persistence migration loses provider data | Low | High | Versioned decoding, atomic writes, round-trip/unknown-field tests |
| Temporary dual path becomes permanent | Medium | High | Phase 9 zero-reference gate and no release before deletion |

## 16. Commit sequence

1. `Document native SSH session migration`
2. `Define native SSH session boundaries`
3. `Implement native direct SSH transport`
4. `Migrate terminal runtime to shared SSH sessions`
5. `Move remote commands onto shared SSH sessions`
6. `Migrate file workflows to native SFTP`
7. `Add administrator SFTP over exec channels`
8. `Add explicit JumpServer target sessions`
9. `Move port forwarding onto shared SSH sessions`
10. `Remove legacy OpenSSH transport paths`
11. `Verify native SSH release packaging`

Commits may be split further when a phase produces independently reviewable code, but
they may not mix unrelated UI cleanup or broad renaming.

## 17. First implementation slice

After this plan is committed, implementation starts with the smallest irreversible-risk
slice:

1. Add final route/session/error/command/filesystem model files in `RemoraCore`.
2. Add contract tests for identity, legal state transitions, replay policy, and strict
   capability separation.
3. Add an empty `RemoraSSHNative` C target boundary with opaque handles and deterministic
   lifecycle tests.
4. Do not migrate UI or activate native SSH yet.
5. Stop and reassess the dependency packaging gate before importing third-party source.

This slice proves module boundaries without entangling current working behavior. It can
be reverted as one isolated commit if the native packaging decision fails.
