#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT_DIR/Vendor/NativeSSH/UPSTREAM.json"
VENDOR_DIR="$ROOT_DIR/Vendor/NativeSSH"

libssh2_version=
libssh2_sha256=
mbedtls_version=
mbedtls_sha256=
replace=0

usage() {
    cat <<'EOF'
Usage: update_native_ssh_dependencies.sh \
  --libssh2-version VERSION --libssh2-sha256 SHA256 \
  --mbedtls-version VERSION --mbedtls-sha256 SHA256 [--replace]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --libssh2-version) libssh2_version=${2-}; shift 2 ;;
        --libssh2-sha256) libssh2_sha256=${2-}; shift 2 ;;
        --mbedtls-version) mbedtls_version=${2-}; shift 2 ;;
        --mbedtls-sha256) mbedtls_sha256=${2-}; shift 2 ;;
        --replace) replace=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
done

if [ -z "$libssh2_version" ] || [ -z "$libssh2_sha256" ] || \
   [ -z "$mbedtls_version" ] || [ -z "$mbedtls_sha256" ]; then
    usage >&2
    exit 64
fi

command -v cmake >/dev/null 2>&1 || { echo "cmake is required for maintainer verification" >&2; exit 69; }
command -v ruby >/dev/null 2>&1 || { echo "ruby is required to read UPSTREAM.json" >&2; exit 69; }

manifest_value() {
    ruby -rjson -e 'data = JSON.parse(File.read(ARGV.shift)); puts ARGV.reduce(data) { |value, key| value.fetch(key) }' \
        "$MANIFEST" "$@"
}

expected_libssh2_version=$(manifest_value dependencies libssh2 version)
expected_libssh2_sha256=$(manifest_value dependencies libssh2 archiveSHA256)
expected_libssh2_url=$(manifest_value dependencies libssh2 archiveURL)
expected_mbedtls_version=$(manifest_value dependencies mbedtls version)
expected_mbedtls_sha256=$(manifest_value dependencies mbedtls archiveSHA256)
expected_mbedtls_url=$(manifest_value dependencies mbedtls archiveURL)

if [ "$libssh2_version" != "$expected_libssh2_version" ] || \
   [ "$libssh2_sha256" != "$expected_libssh2_sha256" ] || \
   [ "$mbedtls_version" != "$expected_mbedtls_version" ] || \
   [ "$mbedtls_sha256" != "$expected_mbedtls_sha256" ]; then
    echo "explicit versions/checksums do not match Vendor/NativeSSH/UPSTREAM.json" >&2
    exit 65
fi

if { [ -d "$VENDOR_DIR/libssh2" ] || [ -d "$VENDOR_DIR/mbedtls" ]; } && [ "$replace" -ne 1 ]; then
    echo "vendor output already exists; inspect changes and pass --replace explicitly" >&2
    exit 73
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/remora-native-ssh.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

libssh2_archive="$work_dir/libssh2.tar.gz"
mbedtls_archive="$work_dir/mbedtls.tar.bz2"
curl --fail --location --silent --show-error --output "$libssh2_archive" "$expected_libssh2_url"
curl --fail --location --silent --show-error --output "$mbedtls_archive" "$expected_mbedtls_url"

verify_sha256() {
    expected=$1
    file=$2
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    [ "$actual" = "$expected" ] || {
        echo "checksum mismatch for $file: expected $expected, got $actual" >&2
        exit 65
    }
}

verify_sha256 "$libssh2_sha256" "$libssh2_archive"
verify_sha256 "$mbedtls_sha256" "$mbedtls_archive"

source_dir="$work_dir/source"
mkdir -p "$source_dir"
tar -xzf "$libssh2_archive" -C "$source_dir"
tar -xjf "$mbedtls_archive" -C "$source_dir"
libssh2_source="$source_dir/libssh2-$libssh2_version"
mbedtls_source="$source_dir/mbedtls-$mbedtls_version"

build_architecture() {
    arch=$1
    build_dir="$work_dir/build-$arch"
    prefix="$build_dir/prefix"

    cmake -S "$mbedtls_source" -B "$build_dir/mbedtls" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DENABLE_PROGRAMS=OFF \
        -DENABLE_TESTING=OFF \
        -DUNSAFE_BUILD=OFF \
        -DMBEDTLS_FATAL_WARNINGS=OFF >"$build_dir-mbedtls-configure.log"
    cmake --build "$build_dir/mbedtls" --target install -j 8 >"$build_dir-mbedtls-build.log"

    cmake -S "$libssh2_source" -B "$build_dir/libssh2" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_ZLIB_COMPRESSION=OFF \
        -DCRYPTO_BACKEND=mbedTLS \
        -DMBEDTLS_INCLUDE_DIR="$prefix/include" \
        -DMBEDCRYPTO_LIBRARY="$prefix/lib/libmbedcrypto.a" >"$build_dir-libssh2-configure.log"
    cmake --build "$build_dir/libssh2" --target install -j 8 >"$build_dir-libssh2-build.log"

    grep -q 'Crypto backend, mbedTLS' "$build_dir-libssh2-configure.log"
    symbols=$(nm -gU "$prefix/lib/libssh2.a")
    for symbol in \
        _libssh2_agent_userauth \
        _libssh2_channel_direct_tcpip_ex \
        _libssh2_channel_process_startup \
        _libssh2_knownhost_checkp \
        _libssh2_sftp_init \
        _libssh2_userauth_keyboard_interactive_ex
    do
        echo "$symbols" | grep -q "$symbol" || {
            echo "required symbol missing for $arch: $symbol" >&2
            exit 65
        }
    done

    cat >"$build_dir/fixture.c" <<'EOF'
#include <libssh2.h>
int main(void) {
    if (libssh2_init(0) != 0) return 1;
    libssh2_exit();
    return 0;
}
EOF
    xcrun clang -arch "$arch" -mmacosx-version-min=14.0 \
        -I"$prefix/include" "$build_dir/fixture.c" \
        "$prefix/lib/libssh2.a" "$prefix/lib/libmbedcrypto.a" \
        -o "$build_dir/fixture"
    dependencies=$(otool -L "$build_dir/fixture")
    echo "$dependencies" | grep -E '/opt/homebrew|/usr/local' >/dev/null && {
        echo "unexpected developer-machine dynamic dependency for $arch" >&2
        exit 65
    }

    lipo -info "$prefix/lib/libssh2.a"
    lipo -info "$prefix/lib/libmbedcrypto.a"
    fixture_size=$(stat -f '%z' "$build_dir/fixture")
    echo "linked fixture size ($arch): $fixture_size bytes"
}

build_architecture arm64
build_architecture x86_64

cmp "$work_dir/build-arm64/libssh2/src/libssh2_config.h" \
    "$work_dir/build-x86_64/libssh2/src/libssh2_config.h"

staging="$work_dir/vendor"
mkdir -p "$staging/libssh2/include" "$staging/libssh2/src" \
    "$staging/mbedtls/include" "$staging/mbedtls/library" \
    "$staging/mbedtls/3rdparty/everest"

cp -R "$libssh2_source/include/." "$staging/libssh2/include/"
cp "$libssh2_source/COPYING" "$staging/libssh2/COPYING"
for file in \
    agent bcrypt_pbkdf channel comp chacha cipher-chachapoly crypt crypto global \
    hostkey keepalive kex knownhost mac misc packet pem poly1305 publickey scp \
    session sftp transport userauth userauth_kbd_packet version
do
    cp "$libssh2_source/src/$file.c" "$staging/libssh2/src/"
done
for embedded_file in agent_win blowfish mbedtls; do
    cp "$libssh2_source/src/$embedded_file.c" "$staging/libssh2/src/"
done
find "$libssh2_source/src" -maxdepth 1 -name '*.h' -exec cp '{}' "$staging/libssh2/src/" ';'
cp "$work_dir/build-arm64/libssh2/src/libssh2_config.h" "$staging/libssh2/src/"

cp -R "$mbedtls_source/include/." "$staging/mbedtls/include/"
cp "$mbedtls_source/LICENSE" "$staging/mbedtls/LICENSE"
find "$mbedtls_source/library" -maxdepth 1 -name '*.h' -exec cp '{}' "$staging/mbedtls/library/" ';'
for file in \
    aes aesni aesce aria asn1parse asn1write base64 bignum bignum_core \
    bignum_mod bignum_mod_raw block_cipher camellia ccm chacha20 chachapoly \
    cipher cipher_wrap constant_time cmac ctr_drbg des dhm ecdh ecdsa ecjpake \
    ecp ecp_curves entropy entropy_poll error gcm hkdf hmac_drbg lmots lms md \
    md5 memory_buffer_alloc nist_kw oid padlock pem pk pk_ecc pk_wrap pkcs12 \
    pkcs5 pkparse pkwrite platform platform_util poly1305 psa_crypto \
    psa_crypto_aead psa_crypto_cipher psa_crypto_client \
    psa_crypto_driver_wrappers_no_static psa_crypto_ecp psa_crypto_ffdh \
    psa_crypto_hash psa_crypto_mac psa_crypto_pake psa_crypto_random \
    psa_crypto_rsa psa_crypto_se psa_crypto_slot_management psa_crypto_storage \
    psa_its_file psa_util ripemd160 rsa rsa_alt_helpers sha1 sha256 sha512 sha3 \
    threading timing version version_features
do
    cp "$mbedtls_source/library/$file.c" "$staging/mbedtls/library/"
done
cp -R "$mbedtls_source/3rdparty/everest/include" "$staging/mbedtls/3rdparty/everest/"
mkdir -p "$staging/mbedtls/3rdparty/everest/library"
for file in everest x25519 Hacl_Curve25519_joined; do
    cp "$mbedtls_source/3rdparty/everest/library/$file.c" \
        "$staging/mbedtls/3rdparty/everest/library/"
done
cp "$mbedtls_source/3rdparty/everest/library/Hacl_Curve25519.c" \
    "$staging/mbedtls/3rdparty/everest/library/"
mkdir -p "$staging/mbedtls/3rdparty/everest/library/kremlib"
cp "$mbedtls_source/3rdparty/everest/library/kremlib/FStar_UInt64_FStar_UInt32_FStar_UInt16_FStar_UInt8.c" \
    "$staging/mbedtls/3rdparty/everest/library/kremlib/"

if [ "$replace" -eq 1 ]; then
    rm -rf "$VENDOR_DIR/libssh2" "$VENDOR_DIR/mbedtls"
fi
mv "$staging/libssh2" "$VENDOR_DIR/libssh2"
mv "$staging/mbedtls" "$VENDOR_DIR/mbedtls"

echo "Native SSH dependencies updated and verified for arm64 and x86_64."
