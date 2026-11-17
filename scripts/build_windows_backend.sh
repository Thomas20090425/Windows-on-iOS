#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
JOBS="${JOBS:-2}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_ROOT="${WINDOWS_BACKEND_BUILD_ROOT:-$ROOT/build/unified/windows}"
OUTPUT="${WINDOWS_BACKEND_OUTPUT:-$ROOT/build/unified/backends/WindowsBackend.framework}"
SPEC="$ROOT/research/Unified/Windows/project.yml"
mkdir -p "$BUILD_ROOT" "$(dirname "$OUTPUT")" "$ROOT/build/logs"
python3 "$ROOT/scripts/prepare_firmware.py"
python3 "$ROOT/scripts/prepare_windows_drivers.py"
if [[ ! -f "$ROOT/ios/deps/lib/libslirp.a" ]]; then
    JOBS="$JOBS" "$ROOT/scripts/build_ios_deps.sh"
fi
JOBS="$JOBS" "$ROOT/scripts/build_ios_tpm_deps.sh"
make -C "$ROOT" -j"$JOBS" ios-lib
xcodegen generate --spec "$SPEC"
xcodebuild -project "$ROOT/research/Unified/Windows/WindowsBackend.xcodeproj" \
    -scheme WindowsBackend -configuration "$CONFIGURATION" -sdk iphoneos \
    -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_ROOT/DerivedData" \
    -jobs "$JOBS" CODE_SIGNING_ALLOWED=NO build
PRODUCT="$BUILD_ROOT/DerivedData/Build/Products/$CONFIGURATION-iphoneos/WindowsBackend.framework"
STAGING="$(mktemp -d "$(dirname "$OUTPUT")/.windows-backend.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$PRODUCT" "$STAGING/WindowsBackend.framework"
if [[ -e "$OUTPUT" ]]; then rm -rf "$OUTPUT"; fi
mv "$STAGING/WindowsBackend.framework" "$OUTPUT"
python3 - "$OUTPUT" "$ROOT/build/unified/backends/windows-backend-symbols.json" <<'PY'
import json, pathlib, re, subprocess, sys
framework = pathlib.Path(sys.argv[1])
binary = framework / 'WindowsBackend'
exports = subprocess.check_output(['nm', '-gU', str(binary)], text=True)
if re.search(r'\b_hv_', exports):
    raise SystemExit('WindowsBackend unexpectedly exports native engine hv_ symbols')
required = ('_winios_jit_helper_token', '_winios_brk_probe_trap',
            '_winios_brk_mapping_trap', '_winios_brk_detach_trap')
symbols = {}
for name in required:
    match = re.search(r'^([0-9a-fA-F]+)\s+\w\s+' + re.escape(name) + r'$', exports, re.M)
    if not match:
        raise SystemExit('Missing JIT export ' + name)
    symbols[name[1:]] = '0x' + match.group(1)
manifest = {
    'framework': str(framework.resolve()),
    'uuid': subprocess.check_output(['dwarfdump', '--uuid', str(binary)], text=True).strip(),
    'jit_symbols': symbols,
    'native_engine_exports_hidden': True,
    'runtime_validation': 'Framework compilation only',
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(manifest, indent=2) + '\n')
PY
echo "Windows framework: $OUTPUT"
