#!/bin/bash
# Two claims on one key must be named loudly, and must fail the export.
set -e

OUT=$(koruc input.k claims 2>&1) || true
echo "$OUT"

echo "$OUT" | grep -q "duplicate claim key"  || { echo "FAIL: collision not reported";    exit 1; }
echo "$OUT" | grep -q "no-alloc"             || { echo "FAIL: colliding rule not named";  exit 1; }
echo "$OUT" | grep -q "measured"             || { echo "FAIL: first stamp not shown";     exit 1; }
echo "$OUT" | grep -q "aspirational"         || { echo "FAIL: second stamp not shown";    exit 1; }

# The JSON export refuses rather than emitting an untrustworthy keyset.
set +e
koruc input.k claims json > /dev/null 2>&1
JSON_STATUS=$?
set -e
[ "$JSON_STATUS" -ne 0 ] || { echo "FAIL: json export succeeded despite a key collision"; exit 1; }

echo "=== PASS: colliding claim keys are named and the export is refused ==="
