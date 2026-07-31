#!/bin/bash
# A gate with every check under its ceiling exits zero; an inference-only
# git-gate invariant is handed to the reviewer as rule text, not failed.

set -e

OUT=$(koruc "$KORU_INPUT" invariants gate 2>&1) && RC=0 || RC=$?

[ "$RC" -eq 0 ] \
    || { echo "FAIL: gate exited $RC with no violated invariant"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "counted-loops-are-for" \
    || { echo "FAIL: checked invariant not named"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "holds" \
    || { echo "FAIL: holding verdict not reported"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "while sites: 3 of 3" \
    || { echo "FAIL: check evidence not shown"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "comment-language" \
    || { echo "FAIL: inference invariant not surfaced by the gate"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "Comments are written in English, not Norwegian." \
    || { echo "FAIL: inference rule text not handed to the reviewer"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "1 held, 0 violated, 1 by inference" \
    || { echo "FAIL: gate tally wrong"; echo "$OUT"; exit 1; }

echo "=== Test passed: gate held and surfaced the inference rule ==="
