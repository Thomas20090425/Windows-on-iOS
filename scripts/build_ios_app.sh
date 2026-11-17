#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Compile the real arm64 device application. Does not launch VMs or run tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
JOBS="${JOBS:-2}"
CONFIGURATION="${CONFIGURATION:-Release}"
DIST_DIR="${DIST_DIR:-$ROOT/distribution}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
MEMORY_CAPABILITIES="${MEMORY_CAPABILITIES:-YES}"
case "$MEMORY_CAPABILITIES" in
    YES|NO) ;;
    *) echo "MEMORY_CAPABILITIES must be YES or NO." >&2; exit 1 ;;
esac
mkdir -p "$DIST_DIR" "$ROOT/build/logs"

for tool in xcodegen xcrun make; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
python3 "$ROOT/scripts/prepare_firmware.py"
python3 "$ROOT/scripts/prepare_windows_drivers.py"
if [[ ! -f "$ROOT/ios/deps/lib/libslirp.a" ]]; then
    JOBS="$JOBS" "$ROOT/scripts/build_ios_deps.sh"
fi
JOBS="$JOBS" "$ROOT/scripts/build_ios_tpm_deps.sh"
make -C "$ROOT" -j"$JOBS" ios-lib
xcodegen generate --spec "$ROOT/ios/project.yml"

signing=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    signing=(-allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic
        "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    if [[ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]]; then
        signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
            CODE_SIGN_IDENTITY="Apple Development" "PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE_SPECIFIER")
    fi
fi
if [[ -n "${BUNDLE_IDENTIFIER:-}" ]]; then
    signing+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_IDENTIFIER")
fi
if [[ -n "${APP_DISPLAY_NAME:-}" ]]; then
    signing+=("APP_DISPLAY_NAME=$APP_DISPLAY_NAME")
fi
if [[ "$MEMORY_CAPABILITIES" == NO ]]; then
    # Keep the original app identity usable with its existing wildcard profile.
    # The file-backed RAM allocator does not require either optional capability.
    basic_entitlements="$DERIVED_DATA/WindowsiOS-basic.entitlements"
    mkdir -p "$DERIVED_DATA"
    python3 - "$ROOT/ios/WindowsiOS.entitlements" "$basic_entitlements" <<'PY'
import pathlib, plistlib, sys
entitlements = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
for key in ('com.apple.developer.kernel.increased-memory-limit',
            'com.apple.developer.kernel.extended-virtual-addressing'):
    entitlements.pop(key, None)
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(entitlements))
PY
    signing+=("CODE_SIGN_ENTITLEMENTS=$basic_entitlements")
fi
xcodebuild -project "$ROOT/ios/WindowsiOS.xcodeproj" -scheme WindowsiOS \
    -configuration "$CONFIGURATION" -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" -jobs "$JOBS" "${signing[@]}" build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/WindowsiOS.app"
APP_STAGING="$(mktemp -d "$DIST_DIR/.app-stage.XXXXXX")"
ditto "$APP" "$APP_STAGING/WindowsiOS.app"
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    # Xcode's incremental products may retain provisioning from an earlier build.
    rm -f "$APP_STAGING/WindowsiOS.app/embedded.mobileprovision"
    rm -rf "$APP_STAGING/WindowsiOS.app/_CodeSignature"
fi
rm -rf "$DIST_DIR/WindowsiOS.app"
mv "$APP_STAGING/WindowsiOS.app" "$DIST_DIR/WindowsiOS.app"
rmdir "$APP_STAGING"
echo "Device app: $DIST_DIR/WindowsiOS.app"
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    codesign --verify --strict "$DIST_DIR/WindowsiOS.app"
    STAGING="$(mktemp -d "${TMPDIR:-/tmp}/winios-package.XXXXXX")"
    trap 'rm -rf "$STAGING"' EXIT
    mkdir -p "$STAGING/Payload"
    ditto "$DIST_DIR/WindowsiOS.app" "$STAGING/Payload/WindowsiOS.app"
    ditto -c -k --keepParent "$STAGING/Payload" "$DIST_DIR/WindowsiOS-development.ipa"
    echo "Development IPA (limited to provisioned devices): $DIST_DIR/WindowsiOS-development.ipa"
else
    echo "Unsigned compile artifact. Set DEVELOPMENT_TEAM to create a signed development IPA."
fi
python3 - "$DIST_DIR" "$MEMORY_CAPABILITIES" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, subprocess, sys
dist = pathlib.Path(sys.argv[1])
app = dist / 'WindowsiOS.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
profile = app / 'embedded.mobileprovision'
manifest = {
    'generated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'sdk': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
    'architecture': 'arm64',
    'bundle_identifier': info['CFBundleIdentifier'],
    'device_families': info['UIDeviceFamily'],
    'minimum_os': info['MinimumOSVersion'],
    'signing': 'development' if profile.exists() else 'unsigned',
    'memory_capabilities_requested': sys.argv[2] == 'YES',
    'guest_ram_fallback': 'lazy shared mapping with fully allocated temporary-file backing',
    'runtime_validation': 'NOT RUN: compilation and packaging only',
    'guest_cpu_model': 'Arm Cortex-A76 r4p1 (virtual)',
    'graphics': 'VirtIO GPU 2D with firmware RAMFB fallback; no accelerated 3D',
}
firmware = app / 'Firmware' / 'provenance.json'
if firmware.exists():
    firmware_info = json.loads(firmware.read_text())
    manifest['bundled_firmware_package'] = firmware_info['package_version']
    manifest['bundled_firmware_package_sha256'] = firmware_info['package_sha256']
    manifest['bundled_firmware_files_sha256'] = firmware_info['files_sha256']
else:
    raise SystemExit('Built app is missing bundled UEFI firmware provenance')
tpm = app / 'TPM' / 'provenance.json'
if not tpm.exists():
    raise SystemExit('Built app is missing software TPM dependency provenance')
manifest['software_tpm_dependencies'] = json.loads(tpm.read_text())
drivers = app / 'WindowsDrivers' / 'provenance.json'
if not drivers.exists():
    raise SystemExit('Built app is missing bundled Windows ARM64 drivers')
manifest['windows_drivers'] = json.loads(drivers.read_text())
if profile.exists():
    payload = subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)], stderr=subprocess.DEVNULL)
    provisioning = plistlib.loads(payload)
    manifest['provisioned_device_count'] = len(provisioning.get('ProvisionedDevices', []))
    manifest['profile_expiration_utc'] = provisioning['ExpirationDate'].isoformat() + 'Z'
    manifest['debugger_entitlement'] = provisioning.get('Entitlements', {}).get('get-task-allow', False)
    signed_entitlements = plistlib.loads(subprocess.check_output(
        ['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
    memory_keys = ('com.apple.developer.kernel.increased-memory-limit',
                   'com.apple.developer.kernel.extended-virtual-addressing')
    manifest['memory_entitlements'] = {
        key: {'signature': signed_entitlements.get(key, False),
              'profile': provisioning.get('Entitlements', {}).get(key, False)}
        for key in memory_keys
    }
    for key in memory_keys:
        if signed_entitlements.get(key) and not provisioning.get('Entitlements', {}).get(key):
            raise SystemExit(f'Provisioning profile does not authorize {key}')
    ipa = dist / 'WindowsiOS-development.ipa'
    manifest['ipa_sha256'] = hashlib.sha256(ipa.read_bytes()).hexdigest()
(dist / 'BUILD_INFO.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
