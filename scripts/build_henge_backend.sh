#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the isolated macOS engine for UTM. Does not install, launch, or modify a guest.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SOURCE="${HENGE_SOURCE_DIR:-$ROOT/work/references/Henge}"
HUSK="$ROOT/work/references/Husk"
OUTPUT="${HENGE_BACKEND_OUTPUT:-$ROOT/build/unified/backends/HengeBackend.framework}"
DERIVED="${HENGE_BACKEND_DERIVED_DATA:-$ROOT/build/unified/HengeDerivedData}"
PATCH="$ROOT/scripts/patches/henge-unified.patch"
JOBS="${JOBS:-2}"
HENGE_REV=7b557301195f130f900b1b4cd105c9ecf0fbc109
HUSK_REV=afe83d45b31194c4cc9f7b3db7ec2c757db8346e
fail() { echo "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "A Mac with full Xcode is required."
[[ "$JOBS" == 1 || "$JOBS" == 2 ]] || fail "JOBS must be 1 or 2."
for tool in git python3 xcodebuild xcrun xcodegen cmake make ditto; do
    command -v "$tool" >/dev/null || fail "Missing $tool. Homebrew dependencies: cmake rustup xcodegen meson ninja pkgconf gettext autoconf automake libtool libarchive."
done
[[ -s "$PATCH" ]] || fail "Missing pinned Henge embedding patch: $PATCH"
mkdir -p "$ROOT/work/references" "$ROOT/build/logs" "$(dirname "$OUTPUT")"
TASK_TMP="$(mktemp -d "$ROOT/work/henge-backend.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
checkout() {
    local url="$1" rev="$2" dir="$3"
    if [[ ! -e "$dir" ]]; then
        git clone --no-checkout --filter=blob:none "$url" "$dir"
        git -C "$dir" fetch --depth 1 origin "$rev"
        git -C "$dir" checkout --detach "$rev"
    fi
    [[ -d "$dir/.git" ]] || fail "Not a Git checkout: $dir"
    [[ "$(git -C "$dir" remote get-url origin)" == "$url" ]] || fail "Unexpected Git origin: $dir"
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$rev" ]] || fail "Unexpected revision at $dir; no checkout or reset performed."
}
checkout https://github.com/Leviidev/Henge.git "$HENGE_REV" "$SOURCE"
# The unified patch is complete relative to the pinned upstream commit; do not also apply the research patch.
# Compare using a separate index, preserving the developer's index and any unexpected local work.
INDEX="$TASK_TMP/Henge.index"
GIT_INDEX_FILE="$INDEX" git -C "$SOURCE" read-tree HEAD
GIT_INDEX_FILE="$INDEX" git -C "$SOURCE" apply --cached "$PATCH"
if ! GIT_INDEX_FILE="$INDEX" git -C "$SOURCE" diff --quiet --; then
    git -C "$SOURCE" diff HEAD --quiet -- || fail "Unexpected tracked Henge edits. Preserve them and refresh the reviewed patch; no files were reset."
    git -C "$SOURCE" apply --check "$PATCH"
    git -C "$SOURCE" apply "$PATCH"
    GIT_INDEX_FILE="$INDEX" git -C "$SOURCE" diff --quiet -- || fail "Source does not match the pinned unified patch."
fi

network_ready=true
for lib in libslirp libglib-2.0 libintl libpcre2-8; do
    [[ -s "$ROOT/ios/deps/lib/$lib.a" ]] || network_ready=false
done
[[ -s "$ROOT/ios/deps/include/slirp/libslirp.h" ]] || network_ready=false
if [[ "$network_ready" != true ]]; then
    JOBS="$JOBS" "$ROOT/scripts/build_ios_deps.sh" > "$ROOT/build/logs/henge-network-build.log" 2>&1
fi
mkdir -p "$SOURCE/ios/deps/lib" "$SOURCE/ios/deps/include" "$SOURCE/ios/deps/legal"
for lib in libslirp libglib-2.0 libintl libpcre2-8; do
    cp "$ROOT/ios/deps/lib/$lib.a" "$SOURCE/ios/deps/lib/"
done
ditto "$ROOT/ios/deps/include/slirp" "$SOURCE/ios/deps/include/slirp"
python3 - "$ROOT" "$SOURCE" <<'PY'
import pathlib,shutil,sys
root,source=map(pathlib.Path,sys.argv[1:]); base=root/'work/ios_deps_build/src'; legal=source/'ios/deps/legal'
for name,destination in [('libslirp-v4.9.1/COPYRIGHT','libslirp-COPYRIGHT'),
 ('glib-2.83.0/LICENSES/LGPL-2.1-or-later.txt','glib-LGPL-2.1-or-later.txt'),
 ('glib-2.83.0/LICENSES/LGPL-2.1-only.txt','glib-LGPL-2.1-only.txt'),
 ('glib-2.83.0/subprojects/proxy-libintl/COPYING','proxy-libintl-COPYING'),
 ('glib-2.83.0/subprojects/pcre2-10.44/COPYING','pcre2-COPYING')]:
    if (base/name).is_file(): shutil.copy2(base/name,legal/destination)
    elif not (legal/destination).is_file(): raise SystemExit(f'Missing required dependency notice: {base/name}')
PY
if [[ ! -s "$SOURCE/ios/deps/lib/libhusk_rppairing.a" ]]; then
    checkout https://github.com/Leviidev/Husk.git "$HUSK_REV" "$HUSK"
    git -C "$HUSK" diff HEAD --quiet -- || fail "The pinned Husk pairing source has local edits."
    export RUSTUP_HOME="$ROOT/work/henge-toolchains/rustup"
    export CARGO_HOME="$ROOT/work/henge-toolchains/cargo"
    export RUSTUP_TOOLCHAIN=1.100.0
    export CARGO_BUILD_JOBS="$JOBS"
    if [[ -x /opt/homebrew/opt/rustup/bin/rustup ]]; then export PATH="/opt/homebrew/opt/rustup/bin:$PATH"; fi
    command -v rustup >/dev/null || fail "Install rustup (brew install rustup); no global shell-profile change is needed."
    rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target aarch64-apple-ios > "$ROOT/build/logs/henge-rust-toolchain.log" 2>&1
    (cd "$HUSK"; ./scripts/build_rppairing_ios.sh) > "$ROOT/build/logs/henge-rppairing-build.log" 2>&1
    cp "$HUSK/build/ios-arm64/lib/libhusk_rppairing.a" "$SOURCE/ios/deps/lib/"
    cp "$HUSK/src/app/Husk/Resources/legal/LICENSES-rppairing-crates.txt" "$SOURCE/ios/deps/legal/"
fi
[[ -s "$SOURCE/ios/deps/legal/LICENSES-rppairing-crates.txt" ]] || fail "The pairing library's dependency notices are missing."
echo "Building Henge's software JIT, Metal renderer, and guest restore stack."
(cd "$SOURCE"; ./tools/build_ios_restore.sh) > "$ROOT/build/logs/henge-backend-restore.log" 2>&1
(cd "$SOURCE"; make -j"$JOBS" ios-lib build/henge-agent.gz build/tl-samples.dmg) > "$ROOT/build/logs/henge-backend-engine.log" 2>&1
xcodegen generate --spec "$SOURCE/ios/embedded.yml" > "$ROOT/build/logs/henge-backend-xcodegen.log" 2>&1
xcodebuild -project "$SOURCE/ios/HengeBackend.xcodeproj" -scheme HengeBackend -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -jobs "$JOBS" \
    CODE_SIGNING_ALLOWED=NO build > "$ROOT/build/logs/henge-backend-build.log" 2>&1 || {
    tail -45 "$ROOT/build/logs/henge-backend-build.log" >&2; fail "Henge framework build failed."
}
FRAMEWORK="$DERIVED/Build/Products/Release-iphoneos/HengeBackend.framework"
python3 - "$FRAMEWORK" <<'PY'
import pathlib,subprocess,sys
binary=pathlib.Path(sys.argv[1])/'HengeBackend'
symbols=subprocess.check_output(['xcrun','nm','-gUj',str(binary)],text=True).splitlines()
required={'_henge_brk_probe','_henge_brk_get_jit_mapping','_henge_brk_jit_detach',
 '_henge_ios_jit_install_trap_handler','_OBJC_CLASS_$_UTMHengeBackend'}
if required-set(symbols): raise SystemExit(f'Missing exported bridge/JIT symbols: {required-set(symbols)}')
if any(name.startswith('_hv_') for name in symbols): raise SystemExit('Native hv_* symbols escaped the Henge framework boundary.')
PY
if [[ -e "$OUTPUT" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUTPUT/Info.plist" 2>/dev/null)" == com.windowsios.HengeBackend ]] || fail "Refusing to replace an unexpected framework at $OUTPUT"
fi
ditto "$FRAMEWORK" "$TASK_TMP/HengeBackend.framework"
if [[ -e "$OUTPUT" ]]; then mv "$OUTPUT" "$TASK_TMP/previous.framework"; fi
mv "$TASK_TMP/HengeBackend.framework" "$OUTPUT"
python3 - "$ROOT" "$SOURCE" "$OUTPUT" "$PATCH" <<'PY'
import datetime,hashlib,json,pathlib,subprocess,sys
root,source,framework,patch=map(pathlib.Path,sys.argv[1:])
receipt={'generated_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'henge_commit':subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip(),
 'source_patch':str(patch.relative_to(root)),'source_patch_sha256':hashlib.sha256(patch.read_bytes()).hexdigest(),
 'framework_sha256':hashlib.sha256((framework/'HengeBackend').read_bytes()).hexdigest(),
 'uuid':subprocess.check_output(['xcrun','dwarfdump','--uuid',str(framework/'HengeBackend')],text=True).strip(),
 'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
 'validation':'iOS arm64 build and exported symbol isolation. No app installation or guest execution.'}
(framework.parent/'HengeBackend-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
echo "Built isolated macOS engine: $OUTPUT"
