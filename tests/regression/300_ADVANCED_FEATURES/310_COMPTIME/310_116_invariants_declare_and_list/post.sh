#!/bin/bash
# `invariants` must REPORT each declaration under its disposition, with name,
# tags, file:line, and rule text — the declaration surface and its reader ship
# together, and the two dispositions print as separate blocks because they are
# opposite gradients.

set -e

OUT=$(koruc "$KORU_INPUT" invariants 2>&1)

echo "$OUT" | grep -q "^inferred$" \
    || { echo "FAIL: inferred block header missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "^aspirational$" \
    || { echo "FAIL: aspirational block header missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q 'comment-language  \["git-gate"\]' \
    || { echo "FAIL: inferred invariant not listed with its tags"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "store-sweep-vectorizes" \
    || { echo "FAIL: aspirational invariant not listed"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "Comments are written in English, not Norwegian." \
    || { echo "FAIL: rule text not reported"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "input.kz:" \
    || { echo "FAIL: declaration site not reported as file:line"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "1 inferred, 1 aspirational" \
    || { echo "FAIL: disposition tally missing"; echo "$OUT"; exit 1; }

echo "=== Test passed: both dispositions listed with rules ==="
