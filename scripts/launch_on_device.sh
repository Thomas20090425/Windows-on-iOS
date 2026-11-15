#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Debugger-assisted device launch. Must be invoked explicitly by the device owner.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:?Usage: launch_on_device.sh DEVICE_ID [BUNDLE_ID]}"
BUNDLE_ID="${2:-me.ammaar.windowsios}"
[[ "$DEVICE" =~ ^[A-Za-z0-9-]+$ && "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "Supply an alphanumeric device identifier and bundle identifier." >&2; exit 1;
}
mkdir -p "$ROOT/work"
LAUNCH_JSON="$(mktemp "$ROOT/work/device-launch.XXXXXX")"
trap 'rm -f "$LAUNCH_JSON"' EXIT
xcrun devicectl device process launch --start-stopped --terminate-existing \
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
echo "Attaching JIT helper. In the app, select a VM and Start to request JIT allocation."
PYTHONPATH="$ROOT/scripts" xcrun lldb -b \
    -o 'script lldb.debugger.SetAsync(False)' \
    -o "device select $CORE_ID" -o "device process attach -p $PID" \
    -o "command script import \"$ROOT/scripts/_lldb_txm_jit.py\"" \
    -o txm_jit_run
