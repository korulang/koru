#!/bin/bash
# An argument to `invariants` is refused: non-zero exit, the argument named,
# and the real surface taught — never the listing with exit 0.

set -e

OUT=$(koruc "$KORU_INPUT" invariants gate 2>&1) && RC=0 || RC=$?

[ "$RC" -ne 0 ] \
    || { echo "FAIL: unknown argument exited 0"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q 'got `gate`' \
    || { echo "FAIL: refused argument not named"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "koruc <file> invariants" \
    || { echo "FAIL: real surface not taught"; echo "$OUT"; exit 1; }
if echo "$OUT" | grep -q "1 inferred"; then
    echo "FAIL: listing printed despite the refusal"; echo "$OUT"; exit 1
fi

echo "=== Test passed: retired spelling refused loudly ==="
