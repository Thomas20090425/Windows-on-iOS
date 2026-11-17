#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the actual UTM frontend with embedded Windows and Henge backends.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team.}"
UTM_SOURCE="${UTM_SOURCE_DIR:-$ROOT/work/references/UTM}"
OUTPUT="${UNIFIED_OUTPUT_DIR:-$ROOT/distribution/unified}"
DERIVED="${UNIFIED_DERIVED_DATA:-$ROOT/build/unified/DerivedData}"
PREFIX="${UNIFIED_BUNDLE_PREFIX:-com.thomas20090425.unifiedresearch}"
JOBS="${JOBS:-2}"
LOG="$ROOT/build/logs/unified-utm-build.log"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer.' >&2; exit 1; }
[[ "$PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'Invalid bundle prefix.' >&2; exit 1; }
for file in UTM.app UTM-ARM-Lab.ipa UNIFIED_PROVENANCE.json; do
    [[ ! -e "$OUTPUT/$file" ]] || { echo "Preserving existing $OUTPUT/$file; choose a new UNIFIED_OUTPUT_DIR." >&2; exit 1; }
done
[[ -d "$UTM_SOURCE/sysroot-ios-arm64" ]] || {
    echo 'Prepare the pinned UTM native dependencies with scripts/build_utm_reference.sh first.' >&2; exit 1;
}
mkdir -p "$ROOT/build/logs" "$ROOT/build/unified/backends" "$OUTPUT"
[[ "$(git -C "$UTM_SOURCE" rev-parse HEAD)" == 5d5e1b180be867c795bbeb03ed80087518c0cdae ]] || {
    echo 'The UTM checkout does not match the reviewed source pin; no reset was performed.' >&2; exit 1;
}
PATCH_INDEX="$(mktemp "$ROOT/build/unified/utm-index.XXXXXX")"
rm "$PATCH_INDEX"
trap 'rm -f "$PATCH_INDEX"' EXIT
GIT_INDEX_FILE="$PATCH_INDEX" git -C "$UTM_SOURCE" read-tree HEAD
GIT_INDEX_FILE="$PATCH_INDEX" git -C "$UTM_SOURCE" apply --cached "$ROOT/scripts/patches/utm-unified.patch"
if ! GIT_INDEX_FILE="$PATCH_INDEX" git -C "$UTM_SOURCE" diff --quiet --; then
    git -C "$UTM_SOURCE" diff HEAD --quiet -- || {
        echo 'UTM contains changes beyond the reviewed patch. Preserve them and refresh the patch before rebuilding.' >&2; exit 1;
    }
    git -C "$UTM_SOURCE" apply --check "$ROOT/scripts/patches/utm-unified.patch"
    git -C "$UTM_SOURCE" apply "$ROOT/scripts/patches/utm-unified.patch"
    GIT_INDEX_FILE="$PATCH_INDEX" git -C "$UTM_SOURCE" diff --quiet -- || {
        echo 'UTM source still differs from the reviewed patch.' >&2; exit 1;
    }
fi
if [[ "${SKIP_BACKEND_BUILDS:-NO}" == YES ]]; then
    echo 'Using the existing native backend build products; provenance checks still run.'
else
    "$ROOT/scripts/build_windows_backend.sh" > "$ROOT/build/logs/unified-windows-backend.log" 2>&1
    "$ROOT/scripts/build_henge_backend.sh" > "$ROOT/build/logs/unified-henge-backend.log" 2>&1
fi
python3 "$ROOT/scripts/prepare_unified_utm_project.py" --source "$UTM_SOURCE"
echo "Building UTM ARM Lab. Log: $LOG"
xcodebuild -project "$UTM_SOURCE/UTMUnified.xcodeproj" -scheme iOS -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    -jobs "$JOBS" -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile \
    -allowProvisioningUpdates "DEVELOPMENT_TEAM=$TEAM" "PRODUCT_BUNDLE_PREFIX=$PREFIX" \
    DEVELOPER_ACCOUNT_PAID=YES DEVELOPER_ACCOUNT_VM_ACCESS=NO CODE_SIGN_STYLE_IOS=Automatic build \
    > "$LOG" 2>&1 || { tail -70 "$LOG" | cut -c1-500 >&2; exit 1; }
APP="$DERIVED/Build/Products/Release-iphoneos/UTM.app"
codesign --verify --deep --strict "$APP"
python3 - "$ROOT" "$UTM_SOURCE" "$APP" "$OUTPUT" "$PREFIX" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, subprocess, sys, tempfile
root, source, app, output = map(pathlib.Path, sys.argv[1:5])
prefix = sys.argv[5]
info = plistlib.loads((app / 'Info.plist').read_bytes())
if info['CFBundleIdentifier'] != prefix + '.UTM':
    raise SystemExit('Unexpected unified app identifier.')
profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')], stderr=subprocess.DEVNULL))
entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
for key in ('get-task-allow', 'com.apple.developer.kernel.increased-memory-limit', 'com.apple.developer.kernel.extended-virtual-addressing'):
    if entitlements.get(key) is not True or profile['Entitlements'].get(key) is not True:
        raise SystemExit('Missing signature/profile authorization: ' + key)
frameworks = {}
for name in ('WindowsBackend', 'HengeBackend'):
    binary = app / 'Frameworks' / (name + '.framework') / name
    if not binary.is_file():
        raise SystemExit('Missing embedded engine ' + name)
    exports = subprocess.check_output(['xcrun', 'nm', '-gUj', str(binary)], text=True).splitlines()
    if any(item.startswith(('_hv_', '_g_', '_slirp_')) for item in exports):
        raise SystemExit('Native dependency symbols escape isolation in ' + name)
    frameworks[name] = {'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                        'uuid': subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(binary)], text=True).strip(),
                        'internal_engine_symbols_hidden': True}
sys.path.insert(0, str(root / 'scripts'))
from jit_symbols import build_manifest as windows_manifest
from _launch_henge_mac_jit import build_manifest as macos_manifest
windows_manifest(app)
macos_manifest(app)
subprocess.run(['ditto', str(app), str(output / 'UTM.app')], check=True)
with tempfile.TemporaryDirectory(prefix='unified-package-', dir=output) as temporary:
    payload = pathlib.Path(temporary) / 'Payload'
    payload.mkdir()
    subprocess.run(['ditto', str(app), str(payload / 'UTM.app')], check=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload), str(output / 'UTM-ARM-Lab.ipa')], check=True)
patches = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
           for path in sorted((root / 'scripts/patches').glob('*unified*.patch'))}
receipt = {'generated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'bundle_identifier': info['CFBundleIdentifier'], 'display_name': info['CFBundleDisplayName'],
           'utm_source_commit': subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
           'frameworks': frameworks, 'patches': patches,
           'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
           'ipa_sha256': hashlib.sha256((output / 'UTM-ARM-Lab.ipa').read_bytes()).hexdigest(),
           'validation': 'Signed source build, isolated exports and both exact-image JIT manifests checked. Guest runtime requires separate verification.',
           'guest_data': 'No existing app container or virtual machine was changed by this build.'}
(output / 'UNIFIED_PROVENANCE.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('Unified app:', output / 'UTM.app')
print('IPA:', output / 'UTM-ARM-Lab.ipa')
print('SHA256:', receipt['ipa_sha256'])
PY
