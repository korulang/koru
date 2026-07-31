#!/bin/bash
# A violated git-gate invariant is a non-zero exit that names the invariant
# and shows the check's evidence. Untagged invariants do not gate.

set -e

OUT=$(koruc "$KORU_INPUT" invariants gate 2>&1) && RC=0 || RC=$?

[ "$RC" -ne 0 ] \
    || { echo "FAIL: gate exited 0 with a violated git-gate invariant"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "counted-loops-are-for" \
    || { echo "FAIL: violated invariant not named"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "VIOLATED" \
    || { echo "FAIL: violation verdict not reported"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "while sites: 3 of 2" \
    || { echo "FAIL: check evidence not shown"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "1 violated" \
    || { echo "FAIL: untagged failing check leaked into the gate tally"; echo "$OUT"; exit 1; }

echo "=== Test passed: gate refused and named the violation ==="
