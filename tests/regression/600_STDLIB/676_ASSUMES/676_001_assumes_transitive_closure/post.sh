#!/bin/bash
# `assumes root` walks root's flow body transitively and reports every
# reachable declaration, graded by its claim — with UNCLAIMED a first-class
# row. The structual point of the audit: a reached declaration without a claim
# is REPORTED, never dropped, and a claimed leaf carries its stamp.

set -e

OUT=$(koruc "$KORU_INPUT" assumes root 2>&1) && RC=0 || RC=$?

[ "$RC" -eq 0 ] \
    || { echo "FAIL: assumes exited $RC"; echo "$OUT"; exit 1; }

echo "$OUT" | grep -q '^📋 assumes — ' \
    || { echo "FAIL: subject header missing"; echo "$OUT"; exit 1; }

# The unclaimed middleman is the finding: reached, reported, stamped unclaimed.
echo "$OUT" | grep -q 'mid  \[unclaimed\]' \
    || { echo "FAIL: unclaimed middleman not reported"; echo "$OUT"; exit 1; }

# The claimed leaf carries its stamp and rule.
echo "$OUT" | grep -q 'leaf  \[proven\] contract-honest' \
    || { echo "FAIL: claimed leaf not reported with stamp"; echo "$OUT"; exit 1; }

# JSON form: same closure, machine-readable.
OUTJ=$(koruc "$KORU_INPUT" assumes root json 2>&1)
echo "$OUTJ" | grep -q '"subject":"' \
    || { echo "FAIL: json subject missing"; echo "$OUTJ"; exit 1; }
echo "$OUTJ" | grep -q '"stamp":"unclaimed"' \
    || { echo "FAIL: json unclaimed stamp missing"; echo "$OUTJ"; exit 1; }

echo "=== Test passed: transitive closure graded by claims ==="