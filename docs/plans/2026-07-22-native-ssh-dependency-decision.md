# Native SSH Dependency Decision

**Status:** Approved and integrated after universal-build proof
**Date:** 2026-07-22  
**Related architecture:** `2026-07-22-native-ssh-session-architecture.md`  

## Decision

Remora will own a narrow C shim over a pinned libssh2 build. The selected dependency
pair is:

| Component | Version | Tag commit | Archive SHA-256 | License choice |
|---|---|---|---|---|
| libssh2 | 1.11.1 | `a312b43325e3383c865a87bb1d26cb52e3292641` | `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7` | BSD-3-Clause |
| mbedTLS | 3.6.7 LTS | `068ff080b369adfac81509f9b57b2afabaf82dc5` | `a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6` | Apache-2.0 option |

The tag object IDs are `3a735286108ad19e3b49c64ebcb66342f1f21df7` for
libssh2 and `da6a8c7b9b8e0c1e236deef2910642657db1a7ec` for mbedTLS. The commit IDs above are
the peeled commits that must be recorded by the vendor manifest.

The checksums cover the official release archives, not GitHub's automatic source-code
archives. In particular, the automatic mbedTLS archive omits the framework submodule and
cannot reproduce an upstream build from the archive alone.

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

The selected libssh2 mbedTLS backend can verify Ed25519 host keys but does not load
Ed25519 private-key files for public-key authentication. That key format must produce a
typed authentication error; it must not trigger an OpenSSH fallback. If Ed25519 private
key authentication is a release requirement, the crypto-backend decision must be
reopened explicitly rather than hidden behind compatibility logic.

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

## Verified dependency gate

The source import is approved after reproducible release builds completed with CMake
4.4.0 and Apple Clang 17.0.0. Both builds target macOS 14.0.

Before changing the pinned dependency pair again, the update script must:

- [x] Run the pinned upstream build for arm64 and x86_64.
- [x] Confirm libssh2 reports the mbedTLS backend.
- [x] Confirm keyboard-interactive, agent, known-host, shell, exec, SFTP, and
  direct-tcpip symbols are present.
- [x] Inspect `otool -L`/`nm` output and prove no external crypto/SSH dylib dependency.
- [x] Measure the linked fixture and static archives.
- [x] Produce the exact SwiftPM/Xcode C source manifests.

The proof produced arm64 archives of approximately 780 KiB (`libmbedcrypto.a`) and
320 KiB (`libssh2.a`), and x86_64 archives of approximately 800 KiB and 320 KiB. No
temporary Homebrew fallback or unverified vendor dump is permitted.
