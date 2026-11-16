#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install only Mac-side transport dependencies; never contact a device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/work/mac-jit-venv"
mkdir -p "$ROOT/work"
MAC_PYTHON="${WINIOS_MAC_PYTHON:-}"
if [[ -z "$MAC_PYTHON" ]]; then
    for candidate in python3.13 python3.14 python3; do
        if command -v "$candidate" >/dev/null 2>&1; then
            MAC_PYTHON="$(command -v "$candidate")"
            break
        fi
    done
fi
[[ -n "$MAC_PYTHON" ]] || { echo "Install Python 3.9 or later, then rerun this command." >&2; exit 1; }
"$MAC_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else "Python 3.9 or later is required")'
if [[ ! -x "$VENV/bin/python" ]]; then
    "$MAC_PYTHON" -m venv "$VENV"
fi
if "$VENV/bin/python" -c 'from importlib.metadata import version; assert version("pymobiledevice3") == "11.55.1"' 2>/dev/null; then
    echo "Mac JIT transport dependencies are ready."
    exit 0
fi
echo "Installing Mac JIT transport dependencies in work/mac-jit-venv (one-time setup)."
if ! "$VENV/bin/python" -m pip install --disable-pip-version-check --prefer-binary \
    -r "$ROOT/scripts/mac_jit_requirements.txt" >"$ROOT/work/mac-jit-setup.log" 2>&1; then
    tail -n 25 "$ROOT/work/mac-jit-setup.log" >&2
    echo "Mac transport setup failed; full log: $ROOT/work/mac-jit-setup.log" >&2
    exit 1
fi
echo "Mac JIT transport dependencies are ready."
