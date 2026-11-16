#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Compile the TPM 2.0 library and cryptography for iOS; never run a test or VM.
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_TPM="$ROOT/work/tpm-deps"
DOWNLOADS="$WORK_TPM/sources"
SOURCES="$WORK_TPM/src"
PREFIX="$WORK_TPM/ios-prefix"
OUT="$ROOT/ios/deps"
JOBS="${JOBS:-2}"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
OPENSSL_VERSION=3.5.9
LIBTPMS_VERSION=0.10.2
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LIBTPMS_SHA256=edac03680f8a4a1c5c1d609a10e3f41e1a129e38ff5158f0c8deaedc719fb127
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
LIBTPMS_URL="https://github.com/stefanberger/libtpms/archive/refs/tags/v$LIBTPMS_VERSION.tar.gz"
OPENSSL_BUILD_ID="ios-arm64-17.0-sdk$SDK_VERSION-openssl$OPENSSL_VERSION-v1"
BUILD_ID="ios-arm64-17.0-sdk$SDK_VERSION-openssl$OPENSSL_VERSION-libtpms$LIBTPMS_VERSION-entropy-v2"
ENTROPY_PATCH="$ROOT/scripts/patches/libtpms-0.10.2-entropy-fail-closed.patch"
mkdir -p "$DOWNLOADS" "$SOURCES" "$PREFIX" "$OUT/lib" "$OUT/include" "$OUT/licenses/TPM"

for tool in perl autoconf automake aclocal autoheader glibtoolize make python3 patch; do
    command -v "$tool" >/dev/null || { echo "Missing TPM build prerequisite: $tool" >&2; exit 1; }
done

fetch() {
    local url="$1" archive="$2" expected="$3"
    if [[ ! -s "$DOWNLOADS/$archive" ]]; then
        curl -fL --retry 3 "$url" -o "$DOWNLOADS/$archive.part"
        mv "$DOWNLOADS/$archive.part" "$DOWNLOADS/$archive"
    fi
    python3 - "$DOWNLOADS/$archive" "$expected" <<'PY'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
actual = hashlib.sha256(path.read_bytes()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit(f'Source checksum mismatch: {path.name}: {actual}')
PY
}

fetch "$OPENSSL_URL" "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
fetch "$LIBTPMS_URL" "libtpms-$LIBTPMS_VERSION.tar.gz" "$LIBTPMS_SHA256"
OPENSSL_SRC="$SOURCES/openssl-$OPENSSL_VERSION"
LIBTPMS_SRC="$SOURCES/libtpms-$LIBTPMS_VERSION"
[[ -f "$OPENSSL_SRC/Configure" ]] || tar -xzf "$DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz" -C "$SOURCES"
[[ -f "$LIBTPMS_SRC/configure.ac" ]] || tar -xzf "$DOWNLOADS/libtpms-$LIBTPMS_VERSION.tar.gz" -C "$SOURCES"
if ! grep -q 'WindowsiOS: a failed CSPRNG' "$LIBTPMS_SRC/src/tpm2/Entropy.c"; then
    (cd "$LIBTPMS_SRC" && patch -p1 < "$ENTROPY_PATCH")
fi

if [[ ! -f "$PREFIX/.$OPENSSL_BUILD_ID" || ! -s "$PREFIX/lib/libcrypto.a" ]]; then
    echo "[build] OpenSSL $OPENSSL_VERSION crypto archive for iOS arm64 (no tests)"
    OPENSSL_BUILD="$WORK_TPM/openssl-ios-build"
    rm -rf "$OPENSSL_BUILD"
    mkdir -p "$OPENSSL_BUILD"
    (
        cd "$OPENSSL_BUILD"
        # Use OpenSSL's official iOS target and the system CSPRNG. No external
        # provider modules, engines, programs or tests are built or executed.
        unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CROSS_COMPILE
        perl "$OPENSSL_SRC/Configure" ios64-xcrun no-shared no-module no-dso no-engine \
            no-async no-tests no-apps no-docs --prefix="$PREFIX" --libdir=lib \
            "-isysroot$SDKROOT" -miphoneos-version-min=17.0 -O2
        make -j"$JOBS" build_libs
        make install_dev
    ) >"$WORK_TPM/openssl-ios-build.log" 2>&1 || {
        tail -n 40 "$WORK_TPM/openssl-ios-build.log" >&2; exit 1;
    }
    touch "$PREFIX/.$OPENSSL_BUILD_ID"
fi

if [[ ! -f "$PREFIX/.$BUILD_ID" || ! -s "$PREFIX/lib/libtpms.a" ]]; then
    echo "[build] libtpms $LIBTPMS_VERSION TPM 2.0 archive for iOS arm64 (no tests)"
    (
        cd "$LIBTPMS_SRC"
        # The upstream tag has autotools inputs, but no generated configure.
        glibtoolize --force
        aclocal
        autoheader
        automake --add-missing -c
        autoconf
    ) >"$WORK_TPM/libtpms-autotools.log" 2>&1 || {
        tail -n 40 "$WORK_TPM/libtpms-autotools.log" >&2; exit 1;
    }
    LIBTPMS_BUILD="$WORK_TPM/libtpms-ios-build"
    rm -rf "$LIBTPMS_BUILD"
    mkdir -p "$LIBTPMS_BUILD"
    (
        cd "$LIBTPMS_BUILD"
        export CC="$(xcrun --sdk iphoneos --find clang) -target arm64-apple-ios17.0"
        export AR="$(xcrun --sdk iphoneos --find ar)"
        export RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
        export NM="$(xcrun --sdk iphoneos --find nm)"
        export CFLAGS="-O2 -isysroot $SDKROOT -fno-common"
        export CPPFLAGS="-I$PREFIX/include"
        export LDFLAGS="-isysroot $SDKROOT -L$PREFIX/lib"
        # Explicit distinct build/host triples force cross compilation; the
        # configure script may compile/link probes but must not execute them.
        "$LIBTPMS_SRC/configure" --build="$("$LIBTPMS_SRC/config.guess")" \
            --host=aarch64-apple-darwin --prefix="$PREFIX" \
            --enable-static --disable-shared --disable-static-tests \
            --without-tpm1 --with-tpm2 --with-openssl
        make -C include -j"$JOBS"
        make -C src -j"$JOBS"
        make -C include install
        make -C src install
    ) >"$WORK_TPM/libtpms-ios-build.log" 2>&1 || {
        tail -n 40 "$WORK_TPM/libtpms-ios-build.log" >&2; exit 1;
    }
    touch "$PREFIX/.$BUILD_ID"
fi

cp "$PREFIX/lib/libtpms.a" "$PREFIX/lib/libcrypto.a" "$OUT/lib/"
rm -rf "$OUT/include/libtpms" "$OUT/include/openssl"
cp -R "$PREFIX/include/libtpms" "$PREFIX/include/openssl" "$OUT/include/"
cp "$LIBTPMS_SRC/LICENSE" "$OUT/licenses/TPM/libtpms-LICENSE.txt"
cp "$OPENSSL_SRC/LICENSE.txt" "$OUT/licenses/TPM/OpenSSL-LICENSE.txt"
cp "$ENTROPY_PATCH" "$OUT/licenses/TPM/libtpms-entropy-fail-closed.patch"
cp "$ROOT/licenses/GPL-3.0.txt" "$ROOT/licenses/TPM-LINKING-NOTICE.txt" "$OUT/licenses/TPM/"
if [[ -f "$OPENSSL_SRC/NOTICE" ]]; then
    cp "$OPENSSL_SRC/NOTICE" "$OUT/licenses/TPM/OpenSSL-NOTICE.txt"
fi
python3 - "$OUT/licenses/TPM/provenance.json" "$BUILD_ID" "$LIBTPMS_URL" "$LIBTPMS_SHA256" "$OPENSSL_URL" "$OPENSSL_SHA256" "$ENTROPY_PATCH" <<'PY'
import hashlib, json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'build': sys.argv[2],
    'libtpms': {'version': '0.10.2', 'source': sys.argv[3], 'sha256': sys.argv[4], 'tpm_versions': ['2.0'],
                'patches': [{'name': pathlib.Path(sys.argv[7]).name,
                             'sha256': hashlib.sha256(pathlib.Path(sys.argv[7]).read_bytes()).hexdigest(),
                             'purpose': 'Reject entropy failure instead of weak simulator rand() fallback'}]},
    'openssl': {'version': '3.5.9', 'source': sys.argv[5], 'sha256': sys.argv[6]},
    'validation': 'Cross compilation only; no tests, debugger, device or VM execution',
}, indent=2) + '\n')
PY
echo "[build] TPM archives, headers and notices staged in $OUT"
