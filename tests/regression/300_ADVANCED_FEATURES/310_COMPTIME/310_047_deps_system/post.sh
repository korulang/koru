#!/bin/bash
# `deps` must REPORT the declarations, not merely exit cleanly.
#
# The previous form was `koruc input.kz deps || true` followed by an
# unconditional "test passed" echo — it asserted nothing, so it stayed green
# while the scan was one level deep and silently ignored imported libraries.

set -e

OUT=$(koruc input.kz deps 2>&1)

for dep in curl zlib nonexistent-lib; do
    echo "$OUT" | grep -q "$dep" || { echo "FAIL: deps did not report '$dep'"; echo "$OUT"; exit 1; }
done

# The toolchain's own requirement, and exactly once — the seeded entry and
# koru_std/compiler.kz's declaration must not both surface.
ZIG_LINES=$(echo "$OUT" | grep -cE '^ +zig ' || true)
[ "$ZIG_LINES" = "1" ] || { echo "FAIL: expected 1 zig line, got $ZIG_LINES"; echo "$OUT"; exit 1; }

echo "=== Test passed: deps reported every declared dependency ==="
