# Native SSH Upstream Sources

Remora vendors the smallest reviewed source surface needed to build libssh2 with the
mbedTLS crypto backend. Normal SwiftPM and Xcode builds never download dependencies and
do not require Homebrew or CMake.

`UPSTREAM.json` is the source of truth for versions, archive URLs, commits, checksums,
and license choices. `SOURCES.json` is the shared compile manifest consumed by SwiftPM
and the generated Xcode project. To update or reproduce the source import, run:

```sh
scripts/update_native_ssh_dependencies.sh \
  --libssh2-version 1.11.1 \
  --libssh2-sha256 d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7 \
  --mbedtls-version 3.6.7 \
  --mbedtls-sha256 a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6 \
  --replace
```

The script verifies both macOS release architectures, confirms the selected crypto
backend and required libssh2 symbols, links a fixture, rejects Homebrew dynamic-library
dependencies, and then replaces the vendored source atomically.

Do not edit files below `libssh2/` or `mbedtls/` manually. Remora-owned configuration
belongs in `Configuration/`.
