#!/bin/bash
# The effective grade is the whole point of `assumes`: a `proven` claim whose
# closure contains an aspirational callee must NOT present as effective proven.
# The authored stamp stays honest; the effective line tells what it rests on.
#
#   claimed [proven] bought-with-debt
#   ↓ effective: unclaimed        <- the finding: proof with no claim beneath
#   bought  [unclaimed]
#   ↓ effective: unclaimed       <- silence, first-class
#   stream  [aspirational] someday-streams
#   ↓ effective: aspirational    <- admitted debt shows as itself

set -e

OUT=$(koruc "$KORU_INPUT" assumes claimed 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: assumes exited $RC"; echo "$OUT"; exit 1; }

# The proven claim keeps its authored stamp...
echo "$OUT" | grep -q 'claimed  \[proven\] bought-with-debt' \
    || { echo "FAIL: authored proven stamp lost"; echo "$OUT"; exit 1; }

# ...but its effective grade is dragged down by the silent closure.
echo "$OUT" | grep -q 'effective: unclaimed' \
    || { echo "FAIL: proven claim over an unclaimed callee reports a clean effective"; echo "$OUT"; exit 1; }

# The aspirational leaf shows its own debt as itself.
echo "$OUT" | grep -q 'stream  \[aspirational\] someday-streams' \
    || { echo "FAIL: aspirational callee not reached"; echo "$OUT"; exit 1; }

# JSON form carries the effective per row.
OUTJ=$(koruc "$KORU_INPUT" assumes claimed json 2>&1)
echo "$OUTJ" | grep -q '"effective":"unclaimed"' \
    || { echo "FAIL: json effective grade missing"; echo "$OUTJ"; exit 1; }

echo "=== Test passed: effective grade = what the closure rests on ==="