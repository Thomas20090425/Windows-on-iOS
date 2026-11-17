#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Debugger-assisted device launch. Must be invoked explicitly by the device owner.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:?Usage: launch_on_device.sh DEVICE_ID [BUNDLE_ID] [APP_PATH]}"
BUNDLE_ID="${2:-me.ammaar.windowsios}"
LOCAL_APP="${3:-${APP_PATH:-$ROOT/distribution/WindowsiOS.app}}"
TRANSPORT="${WINIOS_JIT_TRANSPORT:-batch}"
[[ "$DEVICE" =~ ^[A-Za-z0-9-]+$ && "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "Supply an alphanumeric device identifier and bundle identifier." >&2; exit 1;
}
mkdir -p "$ROOT/work"
LAUNCH_JSON="$(mktemp "$ROOT/work/device-launch.XXXXXX")"
SYMBOLS_JSON="$(mktemp "$ROOT/work/jit-symbols.XXXXXX")"
trap 'rm -f "$LAUNCH_JSON" "$SYMBOLS_JSON"' EXIT
# Preflight the exact local build before touching the device. The resolver will
# later match its Mach-O UUID to a loaded device image, never guess an ASLR slide.
python3 - "$LOCAL_APP" "$BUNDLE_ID" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1]).expanduser().resolve()
try:
    info = plistlib.loads((app / 'Info.plist').read_bytes())
except (OSError, plistlib.InvalidFileException) as error:
    raise SystemExit(f'Cannot read local app {app}: {error}. Build the app first or supply APP_PATH.')
if info.get('CFBundleIdentifier') != sys.argv[2]:
    raise SystemExit(f"Local app bundle identifier {info.get('CFBundleIdentifier')!r} does not match {sys.argv[2]!r}.")
executable = info.get('CFBundleExecutable')
if not isinstance(executable, str) or not executable or Path(executable).name != executable or not (app / executable).is_file():
    raise SystemExit(f'Local app executable is missing or invalid in {app}. Rebuild the app.')
PY
python3 "$ROOT/scripts/jit_symbols.py" --app "$LOCAL_APP" --output "$SYMBOLS_JSON"
echo "Using local app symbols from $LOCAL_APP; the installed build must match."
case "$TRANSPORT" in
    batch)
        # This installs local dependencies only, before launching the device app.
        bash "$ROOT/scripts/prepare_mac_jit.sh"
        ;;
    xcode) ;;
    *) echo "WINIOS_JIT_TRANSPORT must be batch (default) or xcode." >&2; exit 1 ;;
esac
launch_environment=()
if [[ -f "$LOCAL_APP/Frameworks/WindowsBackend.framework/WindowsBackend" ]]; then
    launch_environment=(--environment-variables '{"UTM_NATIVE_ENGINE":"WindowsARM64"}')
fi
xcrun devicectl device process launch --start-stopped --terminate-existing \
    "${launch_environment[@]}" \
    --device "$DEVICE" --json-output "$LAUNCH_JSON" "$BUNDLE_ID"
read -r PID CORE_ID < <(python3 - "$LAUNCH_JSON" "$DEVICE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))['result']
pid = d['process']['processIdentifier']
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit('Invalid process identifier in devicectl response')
device = d.get('device', {}).get('identifier') or sys.argv[2]
if not all(c.isalnum() or c == '-' for c in device):
    raise SystemExit('Invalid device identifier in devicectl response')
print(pid, device)
PY
)
if [[ "$TRANSPORT" == batch ]]; then
    WINIOS_JIT_SYMBOLS_JSON="$SYMBOLS_JSON" \
        "$ROOT/work/mac-jit-venv/bin/python" "$ROOT/scripts/_launch_mac_jit.py" \
        --device "$CORE_ID" --pid "$PID" --app "$LOCAL_APP"
    exit $?
fi
echo "Attaching JIT helper. In the app, select a VM and Start to request JIT allocation."
WINIOS_JIT_SYMBOLS_JSON="$SYMBOLS_JSON" PYTHONPATH="$ROOT/scripts" xcrun lldb -b \
    -o 'script lldb.debugger.SetAsync(False)' \
    -o "command script import \"$ROOT/scripts/_lldb_txm_jit.py\"" \
    -o 'script import _lldb_txm_jit; _lldb_txm_jit.configure_symbol_lookup(lldb.debugger)' \
    -o 'settings set plugin.process.gdb-remote.packet-timeout 300' \
    -o "device select $CORE_ID" -o "device process attach -p $PID" \
    -o txm_jit_run
