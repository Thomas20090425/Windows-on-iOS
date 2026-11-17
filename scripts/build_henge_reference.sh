#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Rebuild the separate pinned Henge iOS app. Never install or launch a device.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SOURCE="$ROOT/work/references/Henge"
HUSK="$ROOT/work/references/Husk"
STIK="$ROOT/work/references/StikJIT"
OUTPUT="${HENGE_OUTPUT_DIR:-$ROOT/distribution/henge-reference-build}"
DERIVED="${HENGE_DERIVED_DATA:-$ROOT/build/DerivedData-Henge-reference}"
TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team.}"
BUNDLE="${HENGE_BUNDLE_IDENTIFIER:-com.thomas20090425.henge}"
JOBS="${JOBS:-2}"
HENGE_REV=7b557301195f130f900b1b4cd105c9ecf0fbc109
HUSK_REV=afe83d45b31194c4cc9f7b3db7ec2c757db8346e
STIK_REV=32287268fa5824f9edce4cb359f5833ce0cf7b00
export RUSTUP_HOME="$ROOT/work/henge-toolchains/rustup"
export CARGO_HOME="$ROOT/work/henge-toolchains/cargo"
export RUSTUP_TOOLCHAIN=1.100.0
export CARGO_BUILD_JOBS="$JOBS"
fail() { echo "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "macOS with full Xcode 27 or later is required."
[[ "$JOBS" == 1 || "$JOBS" == 2 ]] || fail "JOBS must be 1 or 2."
[[ "$TEAM" =~ ^[A-Za-z0-9]{10}$ && "$BUNDLE" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "Invalid DEVELOPMENT_TEAM or HENGE_BUNDLE_IDENTIFIER."
for tool in git python3 xcodebuild xcrun xcodegen cmake make ditto codesign security curl tar; do
    command -v "$tool" >/dev/null || fail "Missing $tool. Install the required tools (Homebrew: cmake rustup xcodegen meson ninja pkgconf gettext autoconf automake libtool libarchive)."
done
if [[ -x /opt/homebrew/opt/rustup/bin/rustup ]]; then
    export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
elif command -v brew >/dev/null && [[ -x "$(brew --prefix rustup 2>/dev/null)/bin/rustup" ]]; then
    export PATH="$(brew --prefix rustup)/bin:$PATH"
fi
command -v rustup >/dev/null || fail "Install rustup (brew install rustup); no shell-profile change is required."
for name in Henge.app Henge-development.ipa HENGE_PROVENANCE.json licenses; do
    [[ ! -e "$OUTPUT/$name" ]] || fail "Output already exists: $OUTPUT/$name. Choose a new HENGE_OUTPUT_DIR to preserve it."
done
mkdir -p "$ROOT/work/references" "$ROOT/build/logs" "$OUTPUT" "$DERIVED"
TASK_TMP="$(mktemp -d "$ROOT/work/henge-build.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT

checkout() {
    local url="$1" revision="$2" directory="$3"
    if [[ ! -e "$directory" ]]; then
        git clone --no-checkout --filter=blob:none "$url" "$directory"
        git -C "$directory" fetch --depth 1 origin "$revision"
        git -C "$directory" checkout --detach "$revision"
    fi
    [[ -d "$directory/.git" ]] || fail "Existing source is not a Git checkout: $directory"
    [[ "$(git -C "$directory" remote get-url origin)" == "$url" ]] || fail "Unexpected source origin: $directory"
    if [[ "$(git -C "$directory" rev-parse --verify HEAD 2>/dev/null || true)" != "$revision" ]]; then
        [[ -z "$(git -C "$directory" status --porcelain)" ]] || fail "Source has changes; use a clean checkout at $directory. No reset was performed."
        git -C "$directory" fetch --depth 1 origin "$revision"
        git -C "$directory" checkout --detach "$revision"
    fi
}

apply_known_patch() {
    local directory="$1" patch="$2" index="$TASK_TMP/$(basename "$1").index"
    # Build the expected patched index separately. Never modify a user's index
    # or reset their checkout just to determine whether the patch is present.
    GIT_INDEX_FILE="$index" git -C "$directory" read-tree HEAD
    GIT_INDEX_FILE="$index" git -C "$directory" apply --cached "$patch"
    if GIT_INDEX_FILE="$index" git -C "$directory" diff --quiet --; then return; fi
    git -C "$directory" diff HEAD --quiet -- || fail "Unexpected tracked edits in $directory; no files were reset."
    git -C "$directory" apply --check "$patch"
    git -C "$directory" apply "$patch"
    GIT_INDEX_FILE="$index" git -C "$directory" diff --quiet -- || fail "Patched checkout does not match the pinned patch."
}

checkout https://github.com/Leviidev/Henge.git "$HENGE_REV" "$SOURCE"
checkout https://github.com/Leviidev/Husk.git "$HUSK_REV" "$HUSK"
checkout https://github.com/StikDebug/StikJIT.git "$STIK_REV" "$STIK"
git -C "$HUSK" diff HEAD --quiet -- || fail "Husk has tracked edits; its pairing source must match the pinned commit."
python3 - "$ROOT" "$SOURCE" <<'PY'
import hashlib,json,pathlib,sys
root, source=map(pathlib.Path,sys.argv[1:]); manifest=json.loads((root/'research/henge-source.json').read_text())
for path,wanted in [(root/manifest['source_patch'],manifest['source_patch_sha256']),
                    (source/manifest['dependencies']['stikjit']['patch'],manifest['dependencies']['stikjit']['patch_sha256'])]:
    if hashlib.sha256(path.read_bytes()).hexdigest()!=wanted: raise SystemExit(f'Pinned patch checksum mismatch: {path}')
PY
apply_known_patch "$SOURCE" "$ROOT/scripts/patches/henge-research.patch"
apply_known_patch "$STIK" "$SOURCE/ci/stikjit-high-address.patch"

network_ready=true
for lib in libslirp libglib-2.0 libintl libpcre2-8; do
    [[ -s "$ROOT/ios/deps/lib/$lib.a" ]] || network_ready=false
done
[[ -f "$ROOT/ios/deps/include/slirp/libslirp.h" ]] || network_ready=false
if [[ "$network_ready" != true ]]; then
    echo "Building the pinned iOS networking libraries; see build/logs/henge-network-build.log."
    JOBS="$JOBS" "$ROOT/scripts/build_ios_deps.sh" > "$ROOT/build/logs/henge-network-build.log" 2>&1
fi
mkdir -p "$SOURCE/ios/deps/lib" "$SOURCE/ios/deps/include" "$SOURCE/ios/deps/legal"
for lib in libslirp libglib-2.0 libintl libpcre2-8; do
    [[ -s "$ROOT/ios/deps/lib/$lib.a" ]] || fail "Networking build did not stage $lib.a."
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
    if not (base/name).is_file(): raise SystemExit(f'Missing dependency notice: {base/name}. Rebuild networking with scripts/build_ios_deps.sh using its complete source cache.')
    shutil.copy2(base/name,legal/destination)
PY

echo "Preparing task-local Rust 1.100.0 and the iOS pairing library."
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target aarch64-apple-ios > "$ROOT/build/logs/henge-rust-toolchain.log" 2>&1
(cd "$HUSK"; ./scripts/build_rppairing_ios.sh) > "$ROOT/build/logs/henge-rppairing-build.log" 2>&1
cp "$HUSK/build/ios-arm64/lib/libhusk_rppairing.a" "$SOURCE/ios/deps/lib/"
cp "$HUSK/src/app/Husk/Resources/legal/LICENSES-rppairing-crates.txt" "$SOURCE/ios/deps/legal/"
echo "Building patched StikJIT; see build/logs/henge-stikjit-build.log."
(
    cd "$STIK"
    xcodegen generate
    xcodebuild archive -project StikJIT.xcodeproj -scheme StikJIT -configuration Release \
        -sdk iphoneos -destination 'generic/platform=iOS' -archivePath build/StikJIT \
        -jobs "$JOBS" BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO -quiet
    xcodebuild -create-xcframework -framework build/StikJIT.xcarchive/Products/Library/Frameworks/StikJIT.framework \
        -output "$TASK_TMP/StikJIT.xcframework"
) > "$ROOT/build/logs/henge-stikjit-build.log" 2>&1
ditto "$TASK_TMP/StikJIT.xcframework" "$SOURCE/ios/deps/StikJIT.xcframework"

echo "Building Henge's restore stack and software JIT/Metal engine."
(cd "$SOURCE"; ./tools/build_ios_restore.sh) > "$ROOT/build/logs/henge-restore-build.log" 2>&1
(cd "$SOURCE"; make -j"$JOBS" ios-lib) > "$ROOT/build/logs/henge-engine-build.log" 2>&1
ENTITLEMENTS="$TASK_TMP/Henge-development.entitlements"
python3 - "$ENTITLEMENTS" <<'PY'
import pathlib,plistlib,sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
 'get-task-allow':True, 'com.apple.developer.kernel.increased-memory-limit':True,
 'com.apple.developer.kernel.extended-virtual-addressing':True}))
PY
(cd "$SOURCE/ios"; xcodegen generate) > "$ROOT/build/logs/henge-xcodegen.log" 2>&1
echo "Building development-signed $BUNDLE; log: build/logs/henge-reference-build.log."
xcodebuild -project "$SOURCE/ios/Henge.xcodeproj" -scheme Henge -configuration Release -sdk iphoneos \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -jobs "$JOBS" -allowProvisioningUpdates \
    "DEVELOPMENT_TEAM=$TEAM" CODE_SIGN_STYLE=Automatic "HENGE_BUNDLE_IDENTIFIER=$BUNDLE" \
    "HENGE_ENTITLEMENTS=$ENTITLEMENTS" build > "$ROOT/build/logs/henge-reference-build.log" 2>&1 || {
    tail -50 "$ROOT/build/logs/henge-reference-build.log" >&2; fail "Henge app build failed; no app was staged.";
}
APP="$DERIVED/Build/Products/Release-iphoneos/Henge.app"
codesign --verify --deep --strict "$APP"
python3 - "$ROOT" "$SOURCE" "$HUSK" "$STIK" "$APP" "$OUTPUT" "$BUNDLE" <<'PY'
import datetime,hashlib,json,pathlib,plistlib,shutil,subprocess,sys,tempfile
root,source,husk,stik,app,output=map(pathlib.Path,sys.argv[1:7]); bundle=sys.argv[7]
receipt={'generated_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'source':json.loads((root/'research/henge-source.json').read_text()),
 'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
 'rust':subprocess.check_output(['rustc','--version'],text=True).strip(),'profiles':{},'hashes':{},
 'validation':'Source build, local JIT symbol preflight and deep/strict signature verification. This script does not install apps or execute a guest.'}
memory=('com.apple.developer.kernel.increased-memory-limit','com.apple.developer.kernel.extended-virtual-addressing')
for binary in [app,app/'PlugIns/HengeJITHelper.appex']:
 info=plistlib.loads((binary/'Info.plist').read_bytes())
 profile=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(binary/'embedded.mobileprovision')],stderr=subprocess.DEVNULL))
 signed=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(binary)],stderr=subprocess.DEVNULL))
 if signed.get('get-task-allow') is not True: raise SystemExit('App/helper must be development-signed.')
 if binary==app:
  if info['CFBundleIdentifier']!=bundle: raise SystemExit('Unexpected app bundle identifier.')
  if signed.get('dynamic-codesigning'): raise SystemExit('Unexpected dynamic-codesigning entitlement.')
  for key in memory:
   if signed.get(key) is not True or profile['Entitlements'].get(key) is not True: raise SystemExit(f'Missing authorized memory capability: {key}')
 elif info['CFBundleIdentifier']!=bundle+'.JITHelper': raise SystemExit('Unexpected helper bundle identifier.')
 receipt['profiles'][info['CFBundleIdentifier']]={'name':profile['Name'],'team':profile['TeamIdentifier'],'device_count':len(profile.get('ProvisionedDevices',[])), 'expires':profile['ExpirationDate'].isoformat()+'Z'}
for directory in (source,husk,stik):
 receipt.setdefault('actual_commits',{})[directory.name]=subprocess.check_output(['git','-C',str(directory),'rev-parse','HEAD'],text=True).strip()
for path in [*sorted((source/'ios/deps/lib').glob('*.a')),source/'ios/deps/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT',
             *sorted((source/'build/ios').glob('libhenge*.a')),root/'scripts/patches/henge-research.patch',source/'ci/stikjit-high-address.patch']:
 receipt['hashes'][str(path.relative_to(root))]=hashlib.sha256(path.read_bytes()).hexdigest()
sys.path.insert(0,str(root/'scripts'))
from _launch_henge_mac_jit import build_manifest
receipt['jit_symbols']=build_manifest(app,bundle)
for name in ('Henge.app','Henge-development.ipa','HENGE_PROVENANCE.json','licenses'):
 if (output/name).exists(): raise SystemExit(f'Output appeared during build; preserved: {output/name}')
with tempfile.TemporaryDirectory(prefix='.henge-stage-',dir=output) as stage:
 stage=pathlib.Path(stage); payload=stage/'Payload'; payload.mkdir()
 subprocess.run(['ditto',str(app),str(payload/'Henge.app')],check=True)
 subprocess.run(['ditto','-c','-k','--keepParent',str(payload),str(stage/'Henge-development.ipa')],check=True)
 receipt['ipa_sha256']=hashlib.sha256((stage/'Henge-development.ipa').read_bytes()).hexdigest()
 legal=stage/'licenses'; legal.mkdir()
 shutil.copy2(source/'LICENSE',legal/'Henge-LICENSE.txt')
 shutil.copy2(source/'docs/licensing.md',legal/'Henge-licensing.md')
 shutil.copytree(source/'ios/Henge/Resources/legal',legal/'upstream-notices')
 shutil.copytree(source/'ios/deps/legal',legal/'rebuilt-dependency-notices')
 (stage/'HENGE_PROVENANCE.json').write_text(json.dumps(receipt,indent=2)+'\n')
 shutil.move(str(payload/'Henge.app'),str(output/'Henge.app'))
 for name in ('Henge-development.ipa','licenses','HENGE_PROVENANCE.json'): shutil.move(str(stage/name),str(output/name))
print('Signed Henge app:',output/'Henge.app')
print('IPA:',output/'Henge-development.ipa')
print('Receipt:',output/'HENGE_PROVENANCE.json')
PY
