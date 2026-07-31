#!/bin/bash
set -e

# Swapped arguments: `input` IS a module here, so the diagnostic must quote the
# line the user meant and exit non-zero.
if OUT=$(koruc deps input 2>&1); then
    echo "FAIL: 'koruc deps input' exited 0 — the module argument was discarded"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "wrong way round" || { echo "FAIL: no swap diagnostic"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "koruc input deps" || { echo "FAIL: diagnostic did not quote the corrected command"; echo "$OUT"; exit 1; }

# Not a module: still refused, but as an unknown argument rather than a swap.
if OUT2=$(koruc deps definitely-not-a-module 2>&1); then
    echo "FAIL: unknown argument accepted"; echo "$OUT2"; exit 1
fi
echo "$OUT2" | grep -q "does not take an argument" || { echo "FAIL: wrong diagnostic for a non-module"; echo "$OUT2"; exit 1; }

# The builtin itself is untouched.
koruc deps > /dev/null 2>&1 || { echo "FAIL: bare 'koruc deps' broke"; exit 1; }

echo "=== Test passed: deps refuses swapped arguments and still checks the toolchain ==="
