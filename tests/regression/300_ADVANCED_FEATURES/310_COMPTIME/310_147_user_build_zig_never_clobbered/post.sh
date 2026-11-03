#!/bin/bash
set -u
cd "$(dirname "$0")"

rm -rf work && mkdir work && cd work

printf '// SENTINEL hand-written build file\nconst std = @import("std");\n' > build.zig
cp "../$KORU_INPUT" prog.kz

OUT=$(koruc prog.kz 2>&1)
STATUS=$?

if ! grep -q "SENTINEL hand-written" build.zig; then
    echo "FAIL: koruc overwrote a build.zig it did not write — silently"
    echo "$OUT"
    exit 1
fi

# If the sentinel survived because koruc refused, the refusal must name the
# file — not leave the user guessing which artifact blocked it.
if [ $STATUS -ne 0 ]; then
    echo "$OUT" | grep -q "build.zig" || { echo "FAIL: refusal does not name build.zig"; echo "$OUT"; exit 1; }
fi

cd ..
rm -rf work
echo "=== Test passed: a user's build.zig is never silently overwritten ==="
