#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Preserve the original Duo defaults while sharing symbol-aware launch logic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${1:-00008160-000E05D036C0000A}"
BUNDLE_ID="${2:-me.ammaar.windowsios}"
LOCAL_APP="${3:-${APP_PATH:-$ROOT/distribution/WindowsiOS.app}}"
exec "$ROOT/scripts/launch_on_device.sh" "$UDID" "$BUNDLE_ID" "$LOCAL_APP"
