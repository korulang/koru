#!/bin/bash
set -u
cd "$(dirname "$0")"

# `explain` is declared in std/explain and documented as running INSTEAD of
# compilation on any program (`koruc main.k explain`). This input does not
# import std/explain — the command's own gate is supposed to carry it.

OUT=$(koruc "$KORU_INPUT" explain 2>&1) || { echo "FAIL: 'explain' refused"; echo "$OUT"; exit 1; }

# The command must produce explain output — its banner or the empty-catalog
# line — not a silent build. "🔧 Running command: explain" is the dispatch
# marker real commands emit.
echo "$OUT" | grep -q "Running command: explain\|📖 explain\|explain —" || {
    echo "FAIL: 'koruc $KORU_INPUT explain' produced no explain output — the verb fell through to a plain build"
    echo "$OUT"
    exit 1
}

echo "=== Test passed: explain dispatches without a user-side import ==="
