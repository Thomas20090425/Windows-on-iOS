#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Explicit development launch of the exact installed Henge build with Mac JIT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:?Usage: launch_henge_on_device.sh DEVICE_ID APP_PATH [BUNDLE_ID]}"
APP="${2:?Supply the exact signed Henge.app installed on the device.}"
ARGS=(--device "$DEVICE" --app "$APP")
if [[ -n "${3:-}" ]]; then ARGS+=(--bundle-id "$3"); fi
# Inspect local files before preparing tools or opening any device connection.
python3 "$ROOT/scripts/_launch_henge_mac_jit.py" --preflight "${ARGS[@]}"
bash "$ROOT/scripts/prepare_mac_jit.sh"
exec "$ROOT/work/mac-jit-venv/bin/python" "$ROOT/scripts/_launch_henge_mac_jit.py" "${ARGS[@]}"
