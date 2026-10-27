#!/bin/bash
set -e

# Command position takes a command the program declares. A leading verb there
# used to be swallowed — the file built, the verb never ran (Q3 in
# challenges/018_FIX_QUEUE.md). Now it refuses and quotes the corrected order.

if OUT=$(koruc "$KORU_INPUT" run 2>&1); then
    echo "FAIL: 'koruc $KORU_INPUT run' exited 0 — trailing 'run' was swallowed"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "leading verb" || { echo "FAIL: no leading-verb diagnostic"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "koruc run $KORU_INPUT" || { echo "FAIL: diagnostic did not quote the corrected command"; echo "$OUT"; exit 1; }

if OUT=$(koruc "$KORU_INPUT" build 2>&1); then
    echo "FAIL: 'koruc $KORU_INPUT build' exited 0"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "koruc build $KORU_INPUT" || { echo "FAIL: build hint missing"; echo "$OUT"; exit 1; }

# A word nobody declared is dead input — refused, not swallowed.
if OUT=$(koruc "$KORU_INPUT" definitely-not-a-command 2>&1); then
    echo "FAIL: undeclared word accepted"; echo "$OUT"; exit 1
fi
echo "$OUT" | grep -q "not a command" || { echo "FAIL: wrong diagnostic for an undeclared word"; echo "$OUT"; exit 1; }

# Controls: a flag in the same slot is not a command word, a declared command
# still dispatches, and the leading form still builds and runs.
koruc "$KORU_INPUT" --check > /dev/null 2>&1 || { echo "FAIL: '--check' broke"; exit 1; }
koruc "$KORU_INPUT" deps > /dev/null 2>&1 || { echo "FAIL: declared 'deps' command broke"; exit 1; }
RUN_OUT=$(koruc run "$KORU_INPUT" 2>&1) || { echo "FAIL: 'koruc run' broke"; echo "$RUN_OUT"; exit 1; }
echo "$RUN_OUT" | grep -q "ran-for-real" || { echo "FAIL: leading run did not execute the program"; echo "$RUN_OUT"; exit 1; }

echo "=== Test passed: dead words in command position refuse; declared commands and flags unaffected ==="
