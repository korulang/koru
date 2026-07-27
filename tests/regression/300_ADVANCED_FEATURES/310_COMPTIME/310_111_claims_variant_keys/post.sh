#!/bin/bash
# The claims registry: prose reaches the report, and the variant is part of the key.
set -e

OUT=$(koruc input.k claims 2>&1)
echo "$OUT"

# Every stamp this program uses is reported, under its own heading.
echo "$OUT" | grep -q "proven (1)"       || { echo "FAIL: proven census missing";       exit 1; }
echo "$OUT" | grep -q "measured (2)"     || { echo "FAIL: measured census missing";     exit 1; }
echo "$OUT" | grep -q "aspirational (1)" || { echo "FAIL: aspirational census missing"; exit 1; }

# The two sort implementations are SEPARATE claims, told apart by variant.
echo "$OUT" | grep -q "sort|zig(reference)" || { echo "FAIL: reference variant not keyed";  exit 1; }
echo "$OUT" | grep -q "sort|zig(optimized)" || { echo "FAIL: optimized variant not keyed";  exit 1; }

# No collision: three claims name rule sorted-output, on three distinct keys.
echo "$OUT" | grep -q "duplicate claim key" && { echo "FAIL: variants collided on one key"; exit 1; } || true

# The prose written beside the claim is carried, not discarded.
echo "$OUT" | grep -q "obviously correct by inspection" || { echo "FAIL: proc prose lost";  exit 1; }
echo "$OUT" | grep -q "Which implementation delivers it" || { echo "FAIL: tor prose lost";  exit 1; }

echo "=== PASS: variant is part of the claim key; prose survives to the report ==="
