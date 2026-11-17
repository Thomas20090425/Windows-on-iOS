#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the separate full UTM iOS reference app; never install or launch it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SOURCE_DIR="${UTM_SOURCE_DIR:-$ROOT/work/references/UTM}"
OUTPUT_DIR="${UTM_OUTPUT_DIR:-$ROOT/distribution/utm-full}"
DERIVED_DATA="${UTM_DERIVED_DATA:-$SOURCE_DIR/build/DerivedData}"
JOBS="${JOBS:-2}"
TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team.}"
BUNDLE_PREFIX="${PRODUCT_BUNDLE_PREFIX:-com.thomas20090425.research}"
SOURCE_COMMIT=5d5e1b180be867c795bbeb03ed80087518c0cdae
ARTIFACT_ID=12087377615
ARTIFACT_RUN=38996133972
ARTIFACT_SHA256=d200793cd39b77c459971e024ae37603ea8b47f0cd813240141f0afb9ef40811
SYSROOT_ZIP="${UTM_SYSROOT_ZIP:-$SOURCE_DIR/Sysroot-ios-arm64-v5.0.8.zip}"
LOG="$ROOT/build/logs/utm-reference-build.log"

fail() { echo "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "Full Xcode on macOS is required."
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "JOBS must be a positive integer."
[[ "$BUNDLE_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "Choose a valid PRODUCT_BUNDLE_PREFIX."
for tool in git python3 xcodebuild xcrun ditto codesign security; do
    command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"
done
for existing in "$OUTPUT_DIR/UTM.app" "$OUTPUT_DIR/UTM-research-signed.ipa" "$OUTPUT_DIR/UTM_PROVENANCE.json"; do
    [[ ! -e "$existing" ]] || fail "Output already exists: $existing. Set UTM_OUTPUT_DIR to a new directory to preserve it."
done
mkdir -p "$ROOT/work/references" "$ROOT/build/logs" "$OUTPUT_DIR"
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    git clone --depth 1 https://github.com/utmapp/UTM.git "$SOURCE_DIR"
fi
if [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
    if [[ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)" ]]; then
        git -C "$SOURCE_DIR" fetch --depth 1 origin "$SOURCE_COMMIT"
        git -C "$SOURCE_DIR" checkout --detach "$SOURCE_COMMIT"
    else
        fail "UTM has tracked changes. Use a separate UTM_SOURCE_DIR for the pinned build."
    fi
fi

if [[ ! -f "$SYSROOT_ZIP" ]]; then
    command -v gh >/dev/null || fail "Download Sysroot-ios-arm64 from https://github.com/utmapp/UTM/actions/runs/$ARTIFACT_RUN/artifacts/$ARTIFACT_ID and set UTM_SYSROOT_ZIP, or install/authenticate GitHub CLI."
    echo "Downloading the official UTM native-dependency artifact with GitHub CLI."
    gh api "repos/utmapp/UTM/actions/artifacts/$ARTIFACT_ID/zip" > "$SYSROOT_ZIP.part"
    mv "$SYSROOT_ZIP.part" "$SYSROOT_ZIP"
fi
python3 - "$SYSROOT_ZIP" "$ARTIFACT_SHA256" "$SOURCE_DIR" <<'PY'
import hashlib, pathlib, subprocess, sys, tempfile, zipfile
archive, expected, source = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('Official UTM sysroot archive checksum mismatch; not extracting.')
marker = source / 'sysroot-ios-arm64/.utm-native-artifact.sha256'
if marker.exists() and marker.read_text().strip() == expected:
    print('Verified official sysroot is already staged.')
else:
    if marker.parent.exists():
        raise SystemExit('Existing sysroot has no matching provenance marker. Use a clean UTM_SOURCE_DIR.')
    with tempfile.TemporaryDirectory(prefix='utm-sysroot-', dir=source) as temporary:
        with zipfile.ZipFile(archive) as zipped:
            if zipped.namelist() != ['sysroot.tgz']:
                raise SystemExit('Unexpected official sysroot ZIP layout.')
            zipped.extract('sysroot.tgz', temporary)
        subprocess.run(['tar', '-xzf', str(pathlib.Path(temporary) / 'sysroot.tgz'), '-C', str(source)], check=True)
    marker.write_text(expected + '\n')
PY

if ! xcrun --sdk iphoneos metal --version >/dev/null 2>&1; then
    echo "Installing the Xcode Metal Toolchain required by UTM's renderer."
    xcodebuild -downloadComponent MetalToolchain
fi
echo "Building full UTM iOS from $SOURCE_COMMIT with $JOBS workers. Log: $LOG"
(
    cd "$SOURCE_DIR"
    xcodebuild -project UTM.xcodeproj -scheme iOS -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED_DATA" \
        -jobs "$JOBS" -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile \
        -allowProvisioningUpdates "DEVELOPMENT_TEAM=$TEAM" "PRODUCT_BUNDLE_PREFIX=$BUNDLE_PREFIX" \
        DEVELOPER_ACCOUNT_PAID=YES DEVELOPER_ACCOUNT_VM_ACCESS=NO CODE_SIGN_STYLE_IOS=Automatic build
) > "$LOG" 2>&1 || { tail -60 "$LOG" >&2; fail "UTM build failed; no app was staged."; }

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/UTM.app"
codesign --verify --deep --strict "$APP"
python3 - "$ROOT" "$SOURCE_DIR" "$APP" "$OUTPUT_DIR" "$BUNDLE_PREFIX" "$ARTIFACT_SHA256" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, shutil, subprocess, sys, tempfile
root, source, app, output = map(pathlib.Path, sys.argv[1:5])
prefix, artifact_hash = sys.argv[5:7]
profiles = {}
for bundle in (app, app / 'Extensions/iOSHelper.appex'):
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision')], stderr=subprocess.DEVNULL))
    entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL))
    if not entitlements.get('get-task-allow'):
        raise SystemExit(f'{bundle.name} is not development-signed.')
    profiles[info['CFBundleIdentifier']] = {'name': profile['Name'], 'team': profile['TeamIdentifier'], 'device_count': len(profile.get('ProvisionedDevices', []))}
    if bundle == app:
        if info['CFBundleIdentifier'] != prefix + '.UTM':
            raise SystemExit('Unexpected UTM bundle identifier.')
        for key in ('com.apple.developer.kernel.increased-memory-limit', 'com.apple.developer.kernel.extended-virtual-addressing'):
            if entitlements.get(key) is not True or profile['Entitlements'].get(key) is not True:
                raise SystemExit(f'Missing authorized UTM memory capability: {key}')
subprocess.run(['ditto', str(app), str(output / 'UTM.app')], check=True)
with tempfile.TemporaryDirectory(prefix='utm-package-', dir=output) as temporary:
    payload = pathlib.Path(temporary) / 'Payload'
    payload.mkdir()
    subprocess.run(['ditto', str(app), str(payload / 'UTM.app')], check=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload), str(output / 'UTM-research-signed.ipa')], check=True)
licenses = output / 'licenses'
licenses.mkdir(exist_ok=True)
shutil.copy2(source / 'LICENSE', licenses / 'UTM-Apache-2.0.txt')
shutil.copy2(source / 'Platform/iOS/Settings.bundle/License.plist', licenses / 'ThirdParty-Licenses.plist')
shutil.copytree(source / 'sysroot-ios-arm64/share/doc', licenses / 'native-dependency-docs', dirs_exist_ok=True)
receipt = {
    'generated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'source_repository': 'https://github.com/utmapp/UTM',
    'source_commit': subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
    'native_artifact': {'workflow_run': 38996133972, 'artifact_id': 12087377615, 'name': 'Sysroot-ios-arm64', 'release': 'v5.0.8', 'release_source_commit': '535d6592a8bdc22b48de53703a371b80bf60d587', 'sha256': artifact_hash},
    'package_resolved': json.loads((source / 'UTM.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text()),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'profiles': profiles,
    'ipa_sha256': hashlib.sha256((output / 'UTM-research-signed.ipa').read_bytes()).hexdigest(),
    'validation': 'Source build and deep/strict signature verification only; no install or guest execution by this script.',
    'native_compatibility': 'Current pinned frontend built against the official v5.0.8 native sysroot; runtime compatibility remains unverified.'
}
(output / 'UTM_PROVENANCE.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('Signed UTM reference app:', output / 'UTM.app')
print('IPA:', output / 'UTM-research-signed.ipa')
print('SHA256:', receipt['ipa_sha256'])
PY
