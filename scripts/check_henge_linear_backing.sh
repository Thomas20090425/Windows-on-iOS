#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/build/henge-graphics"
mkdir -p "$OUTPUT"
python3 - "$ROOT/work/references/Henge/devices/pvg_metal.m" "$OUTPUT/linear_backing_impl.h" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('/* BEGIN LINEAR BACKING:')
end = source.index('/* END LINEAR BACKING */', start)
pathlib.Path(sys.argv[2]).write_text(source[start:end])
PY
xcrun --sdk macosx clang -fobjc-arc -O1 -Wall -Wextra -I"$OUTPUT" \
    "$ROOT/research/Unified/Graphics/test_linear_backing.m" \
    -framework Foundation -framework Metal -o "$OUTPUT/test_linear_backing"
MTL_DEBUG_LAYER=1 "$OUTPUT/test_linear_backing"
