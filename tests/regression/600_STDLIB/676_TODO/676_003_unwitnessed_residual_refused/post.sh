#!/bin/bash
# A residual naming no test is refused with a non-zero exit, is named as
# undrivable, and the refusal teaches what to do instead. A listing that
# reported it with exit 0 would be a gate that checks nothing.

set -e

OUT=$(koruc "$KORU_INPUT" todo 2>&1) && RC=0 || RC=$?

[ "$RC" -ne 0 ] \
    || { echo "FAIL: unwitnessed residual exited 0"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "MISSING" \
    || { echo "FAIL: missing witness not named as missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "cannot be driven" \
    || { echo "FAIL: refusal does not say the residual cannot be driven"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "red today and green when it is" \
    || { echo "FAIL: refusal does not teach what a witness is"; echo "$OUT"; exit 1; }

echo "=== Test passed: a residual with no witness is refused ==="
