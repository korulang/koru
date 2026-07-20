#!/bin/bash
# The `explain` command discovers a library's ~[explainer], calls it, and renders
# the returned ExplainReport. Assert text prose + property rows, and TYPED json
# (integers stay integers, strings are quoted) — the tagged-union value payoff.
set -e

echo "=== koruc input.kz explain (text) ==="
TEXT=$(koruc input.kz explain 2>&1)
echo "$TEXT"
echo "$TEXT" | grep -q "demo/store"          || { echo "FAIL: report title missing";    exit 1; }
echo "$TEXT" | grep -q "stores = 3"          || { echo "FAIL: counter property missing"; exit 1; }
echo "$TEXT" | grep -q "users.layout = SoA"  || { echo "FAIL: string property missing";  exit 1; }

echo "=== koruc input.kz explain json (typed) ==="
JSON=$(koruc input.kz explain json 2>&1)
echo "$JSON" | grep -q '"stores":3'             || { echo "FAIL: integer not emitted as typed JSON number"; exit 1; }
echo "$JSON" | grep -q '"users.layout":"SoA"'   || { echo "FAIL: string not emitted as quoted JSON";       exit 1; }

echo "=== PASS: explain renders text + typed json ==="
