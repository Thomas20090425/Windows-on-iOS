#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install a development-signed app; does not launch it or overwrite VM media.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:?Usage: install_on_device.sh DEVICE_ID [APP_PATH]}"
APP="${2:-$ROOT/distribution/WindowsiOS.app}"
[[ -d "$APP" ]] || { echo "Application not found: $APP" >&2; exit 1; }
[[ -f "$APP/embedded.mobileprovision" ]] || {
    echo "This application is unsigned. Build with DEVELOPMENT_TEAM set before installing." >&2
    exit 1
}
codesign --verify --strict "$APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed. Import your own media in the VM Library, then use launch_on_device.sh for debugger-assisted JIT."
