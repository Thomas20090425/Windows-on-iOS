#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Explicitly relaunch the unified app with the selected engine's JIT protocol.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:?Usage: launch_unified_on_device.sh DEVICE_ID windows|macos [APP_PATH]}"
ENGINE="${2:?Choose windows or macos. Shut down the running guest before relaunching.}"
APP="${3:-$ROOT/distribution/unified/UTM.app}"
BUNDLE_ID="$(python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
for name in ('WindowsBackend', 'HengeBackend'):
    if not (app / 'Frameworks' / (name + '.framework') / name).is_file():
        raise SystemExit('This app does not contain both unified native backends.')
print(info['CFBundleIdentifier'])
PY
)"
case "$ENGINE" in
    windows) exec "$ROOT/scripts/launch_on_device.sh" "$DEVICE" "$BUNDLE_ID" "$APP" ;;
    macos) exec "$ROOT/scripts/launch_henge_on_device.sh" "$DEVICE" "$APP" "$BUNDLE_ID" ;;
    *) echo 'Choose windows or macos.' >&2; exit 1 ;;
esac
