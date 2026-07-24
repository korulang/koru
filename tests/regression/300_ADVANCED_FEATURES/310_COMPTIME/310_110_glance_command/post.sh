#!/bin/bash
# glance prints the program's declaration surface — no `import std/glance` needed
# (implicit injection). It must show std/store's CRUD events with signatures;
# --app must drop std modules.
set -e

echo "=== koruc input.k glance ==="
OUT=$(koruc input.k glance 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "std.store"                 || { echo "FAIL: std.store module not glanced"; exit 1; }
echo "$OUT" | grep -qE "new\(.*Program.*\) -> SiteResult" || { echo "FAIL: new signature not shown";  exit 1; }
echo "$OUT" | grep -qE "insert\("                 || { echo "FAIL: insert event not surfaced";  exit 1; }
echo "$OUT" | grep -qE "take\("                    || { echo "FAIL: take event not surfaced";    exit 1; }

echo "=== koruc input.k glance --app (drops std) ==="
APP=$(koruc input.k glance --app 2>&1)
echo "$APP"
echo "$APP" | grep -q "std.store" && { echo "FAIL: --app should have dropped std.store"; exit 1; } || true

echo "=== PASS: glance surfaces the store CRUD events; --app filters std ==="
