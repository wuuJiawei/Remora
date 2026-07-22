# Native SSH Dependency Decision

**Status:** Versions selected; source integration blocked by the universal-build proof  
**Date:** 2026-07-22  
**Related architecture:** `2026-07-22-native-ssh-session-architecture.md`  

## Decision

Remora will own a narrow C shim over a pinned libssh2 build. The selected dependency
pair is:

| Component | Version | Tag commit | Archive SHA-256 | License choice |
|---|---|---|---|---|
| libssh2 | 1.11.1 | `a312b43325e3383c865a87bb1d26cb52e3292641` | `82b35c61c78b475647bdc981a183c5b5ab0d979e1caee94186e8f9150f2b0d0d` | BSD-3-Clause |
| mbedTLS | 3.6.7 LTS | `068ff080b369adfac81509f9b57b2afabaf82dc5` | `7312b70b067b6a271961c8d36c3b8f9ba3e86fe6b26f18af13cd70430ee52ed1` | Apache-2.0 option |

The tag object IDs are `3a735286108ad19e3b49c64ebcb66342f1f21df7` for
libssh2 and `da6a8c7b9b8e0c1e236deef2910642657db1a7ec` for mbedTLS. The commit IDs above are
the peeled commits that must be recorded by the vendor manifest.

mbedTLS 4.x is not selected. libssh2 currently declares support for mbedTLS 3.1.0
through 3.6.x, so selecting 4.x would put Remora outside the supported backend matrix.

## Packaging model

Normal Remora builds must satisfy all of these constraints:

- `swift build` works without Homebrew, CMake, or a separately installed native library.
- The generated Xcode release project builds arm64 and x86_64.
- The packaged app has no `/opt/homebrew`, `/usr/local`, or other developer-machine
  dylib dependency.
- libssh2 and mbedTLS symbols are statically linked behind `RemoraSSHNative`.
- Swift business modules never import libssh2 or mbedTLS directly.
- Third-party source, license, version, and checksum are recorded in one manifest.

The preferred implementation is source vendoring in isolated C targets, compiled by
SwiftPM/Xcode as part of the ordinary build. CMake may be required by the maintainer-only
dependency update/proof script, but it cannot be required to build Remora after the
sources and generated configuration are committed.

Proposed target dependency graph:

```text
RemoraApp
  -> RemoraCore
       -> RemoraSSHNative
            -> RemoraLibSSH2
                 -> RemoraMbedCrypto
```

`RemoraMbedCrypto` exposes only headers required by libssh2. `RemoraLibSSH2` is not a
package product. `RemoraSSHNative` is not a package product. Only `RemoraCore` owns and
wraps native handles.

## Source layout

```text
Vendor/NativeSSH/
  UPSTREAM.json
  LICENSES/libssh2-COPYING
  LICENSES/mbedtls-LICENSE
  libssh2/
  mbedtls/
scripts/update_native_ssh_dependencies.sh
Sources/RemoraSSHNative/
```

The update script must:

1. Require explicit versions and expected SHA-256 values.
2. Download release archives over HTTPS.
3. Verify checksums before extraction.
4. Extract only the source/header/license files in the compile manifest.
5. Generate the libssh2 platform configuration deterministically.
6. Reject dirty vendor output unless `--replace` is explicitly supplied.
7. Build arm64 and x86_64 in a temporary directory.
8. Print library architectures and linked dependencies.
9. Never download or modify dependencies during an ordinary app build.

## Why mbedTLS

- libssh2 has a maintained first-party mbedTLS backend.
- 3.6 is an LTS line and 3.6.7 is the latest compatible release inspected on
  2026-07-22.
- It is materially smaller than bundling the OpenSSL/AWS-LC surface needed only for SSH.
- Apache-2.0 is compatible with Remora's distribution model when notices are retained.
- It avoids relying on macOS private OpenSSL/LibreSSL compatibility libraries.

This selection does not imply enabling every mbedTLS algorithm. The committed config
must keep only the algorithms required by libssh2 and Remora's compatibility policy,
with modern algorithms preferred and legacy algorithms opt-in only where the existing
product explicitly supports them.

## Audited alternatives

### `SteveShi/libssh2-swift`

Useful reference for a remote binary XCFramework workflow, but rejected as a dependency:

- Requires macOS 15 while Remora supports macOS 14.
- Uses an externally published binary built with AWS-LC.
- The inspected high-level session uses blocking libssh2 operations.
- It does not provide Remora's required session/lease/channel ownership model.
- Depending on a new third-party binary artifact would move the critical supply-chain
  boundary outside Remora's control.

### `RuiNelson/SwiftSFTP`

Useful reference for explicit libssh2 source lists and low-level type coverage, but
rejected as a dependency:

- Requires Swift tools 6.3 while Remora's documented baseline is Swift 6.0/Xcode 15.4+.
- Brings OpenSSL binary artifacts and additional packages unrelated to the core
  transport boundary.
- Its product API is SFTP-oriented; Remora requires one shared shell/exec/SFTP/forward
  session and a custom authentication coordinator.

### Volt

Rejected because its development build requires Homebrew libssh2/OpenSSL and its release
packaging copies/relinks those dylibs. That does not satisfy clean-machine SwiftPM builds
or Remora's reproducible dependency boundary.

### AWS-LC/OpenSSL backend

Technically viable and used by existing packages, but not selected for the first
implementation. It increases source/binary size and cryptographic surface without a
Remora requirement that mbedTLS 3.6 cannot meet. It remains a contingency only if the
mbedTLS proof fails a required algorithm or key-format test.

### Homebrew/system library

Rejected for production. It is acceptable only as an engineer's comparison fixture and
must never be selected by automatic runtime lookup.

## Open gate

The version decision is complete, but source import is intentionally not approved yet.
The current development machine does not have `cmake`, so the planned upstream universal
static-build proof could not run. Installing developer software globally was outside
this change and was not performed.

Before vendor source is committed:

- [ ] Run the pinned upstream build for arm64 and x86_64.
- [ ] Confirm libssh2 reports the mbedTLS backend.
- [ ] Confirm required algorithms/key formats for existing Remora compatibility tests.
- [ ] Confirm keyboard-interactive, agent, known-host, shell, exec, SFTP, and
  direct-tcpip symbols are present.
- [ ] Inspect `otool -L`/`nm` output and prove no external crypto/SSH dylib dependency.
- [ ] Measure stripped static size.
- [ ] Produce the exact SwiftPM/Xcode C source manifests.

Until these checks pass, the repository keeps only the native ABI skeleton. No temporary
Homebrew fallback and no unverified vendor dump will be added.
