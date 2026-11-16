#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Finder entry point: prepare build tools and compile the iOS app; never run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JOBS="${JOBS:-2}"
BUILD_LOG="$ROOT/build/logs/one-click-build.log"

finish() {
    local status=$?
    trap - EXIT
    echo
    if [[ "$status" -eq 0 ]]; then
        echo "Build completed. Products: $ROOT/distribution/"
    else
        echo "Build stopped (exit $status). Resolve the message above and open Build.command again." >&2
    fi
    if [[ -f "$BUILD_LOG" ]]; then
        echo "Build log: $BUILD_LOG"
    fi
    if [[ -t 0 && -t 1 ]]; then
        read -r -p "Press Return to close this window. " _ || true
    fi
    exit "$status"
}
trap finish EXIT

fail() { echo "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "This build requires macOS and full Xcode with the iOS SDK."
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "JOBS must be a positive whole number (default: 2)."
cd "$ROOT"

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$developer_dir" == *.app ]]; then
    developer_dir="$developer_dir/Contents/Developer"
fi
[[ -d "$developer_dir/Platforms/iPhoneOS.platform" ]] || fail \
    "Install full Xcode, open it once, and select it in Xcode > Settings > Locations > Command Line Tools. Command Line Tools alone are insufficient."
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || fail \
    "The selected Xcode has no usable iOS SDK. Open Xcode and install its iOS platform components, then try again."
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || fail \
    "Open Xcode once, accept its license and allow first-launch components to finish installing, then try again."

# Homebrew's gettext/libarchive tools can be installed but not linked.
brew_prefix=""
if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix)"
    export PATH="$brew_prefix/bin:$brew_prefix/opt/gettext/bin:$brew_prefix/opt/libarchive/bin:$PATH"
fi

missing_formulae=()
need_tool() {
    local tool="$1" formula="$2" existing
    if command -v "$tool" >/dev/null 2>&1; then
        return
    fi
    # Bash 3.2 (macOS /bin/bash) treats an empty array as unset with set -u.
    for existing in "${missing_formulae[@]-}"; do
        [[ "$existing" == "$formula" ]] && return
    done
    missing_formulae+=("$formula")
}

need_tool xcodegen xcodegen
need_tool meson meson
need_tool ninja ninja
need_tool pkg-config pkgconf
need_tool msgfmt gettext
need_tool autoconf autoconf
need_tool autoheader autoconf
need_tool automake automake
need_tool aclocal automake
need_tool glibtoolize libtool
need_tool bsdtar libarchive
if ! python3 -c 'import sys, lzma, ssl; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    missing_formulae+=(python)
fi

if [[ -n "${missing_formulae[*]-}" ]]; then
    [[ -n "$brew_prefix" ]] || fail \
        "Missing build tools: ${missing_formulae[*]}. Install Homebrew from https://brew.sh, then open Build.command again."
    echo "Installing missing build tools with Homebrew: ${missing_formulae[*]}"
    brew install "${missing_formulae[@]}"
    hash -r
fi

for tool in xcodegen meson ninja pkg-config msgfmt autoconf autoheader automake aclocal glibtoolize bsdtar python3 perl curl tar patch make; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required build tool is still unavailable: $tool"
done
python3 -c 'import sys, lzma, ssl; sys.exit(sys.version_info < (3, 9))' || fail \
    "Python 3.9 or newer with lzma/SSL is required. Check your Python installation/PATH."

echo "Building WindowsiOS with $JOBS workers. The first build downloads dependencies, firmware and drivers."
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "Development signing requested; Xcode needs an account for DEVELOPMENT_TEAM and a usable signing identity."
else
    echo "Creating an unsigned compile artifact. Set DEVELOPMENT_TEAM to build a device-installable development app/IPA."
fi
mkdir -p "$(dirname "$BUILD_LOG")"
"$ROOT/scripts/build_ios_app.sh" 2>&1 | tee "$BUILD_LOG"
