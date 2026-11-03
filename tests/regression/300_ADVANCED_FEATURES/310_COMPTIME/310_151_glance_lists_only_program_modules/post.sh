#!/bin/bash
set -u
cd "$(dirname "$0")"

# glance's job is "the program's declaration surface". std.compiler is the
# compiler's own injected environment — this program never imports it and
# cannot reach it. It does not belong in the program's surface, or must be
# labelled as env rather than program.
OUT=$(koruc "$KORU_INPUT" glance 2>&1) || { echo "FAIL: glance exited non-zero"; echo "$OUT"; exit 1; }

if echo "$OUT" | grep -q "std.compiler"; then
    echo "FAIL: glance lists std.compiler — injected compiler machinery presented as the program's declarations"
    echo "$OUT" | head -10
    exit 1
fi

# Control: the module the program DID import stays listed.
echo "$OUT" | grep -q "std.io\|main" || { echo "FAIL: glance lost the program's real surface"; echo "$OUT"; exit 1; }

echo "=== Test passed: glance lists only modules the program declares or imports ==="
