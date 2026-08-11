#!/bin/bash
# An argument to `todo` is refused: non-zero exit, the argument named, and the
# real surface taught — never the listing with exit 0.

set -e

OUT=$(koruc "$KORU_INPUT" todo list 2>&1) && RC=0 || RC=$?

[ "$RC" -ne 0 ] \
    || { echo "FAIL: unknown argument exited 0"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q 'got `list`' \
    || { echo "FAIL: refused argument not named"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "koruc <file> todo" \
    || { echo "FAIL: real surface not taught"; echo "$OUT"; exit 1; }
if echo "$OUT" | grep -q "1 owed"; then
    echo "FAIL: listing printed despite the refusal"; echo "$OUT"; exit 1
fi

echo "=== Test passed: unknown subcommand refused loudly ==="
