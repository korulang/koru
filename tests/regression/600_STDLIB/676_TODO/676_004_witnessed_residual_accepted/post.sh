#!/bin/bash
# A residual naming a real, asserting test is ACCEPTED: exit 0, the witness
# echoed plainly, and none of the three refusal words anywhere in the output.
#
# The witness is resolved by climbing from this directory — six levels below the
# repo root — so a pass here is also proof the corpus lookup is not relative to
# the manifest's location.

set -e

OUT=$(koruc "$KORU_INPUT" todo 2>&1) && RC=0 || RC=$?

[ "$RC" -eq 0 ] \
    || { echo "FAIL: a witnessed residual was refused (exit $RC)"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "witness  675_001_invariants_declare_without_executing" \
    || { echo "FAIL: witness not resolved from a nested directory"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "1 owed" \
    || { echo "FAIL: the residual was not counted"; echo "$OUT"; exit 1; }
for bad in MISSING "NOT FOUND" VACUOUS; do
    if echo "$OUT" | grep -q "$bad"; then
        echo "FAIL: refusal '$bad' fired on a drivable residual"; echo "$OUT"; exit 1
    fi
done

echo "=== Test passed: a witnessed residual is accepted, witness resolved by climbing ==="
