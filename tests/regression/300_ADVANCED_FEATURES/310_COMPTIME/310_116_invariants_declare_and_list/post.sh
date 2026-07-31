#!/bin/bash
# `invariants` must REPORT each declaration with its disposition and rule —
# the declaration surface and its reader ship together.

set -e

OUT=$(koruc "$KORU_INPUT" invariants 2>&1)

echo "$OUT" | grep -q "comment-language (inferred)" \
    || { echo "FAIL: inferred invariant not listed with its disposition"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "store-sweep-vectorizes (aspirational)" \
    || { echo "FAIL: aspirational invariant not listed with its disposition"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "Comments are written in English, not Norwegian." \
    || { echo "FAIL: rule text not reported"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "\[git-gate\]" \
    || { echo "FAIL: git-gate tag not reported"; echo "$OUT"; exit 1; }

echo "=== Test passed: both dispositions listed with rules ==="
