#!/bin/bash
# std/store's explainer reports its OWN decisions, derived from the call-forms:
# 2 stores, both singleton, one field each, `global` watched once, `game` zero.
set -e

echo "=== koruc input.k explain (text) ==="
TEXT=$(koruc input.k explain 2>&1)
echo "$TEXT"
echo "$TEXT" | grep -q "std/store"          || { echo "FAIL: no std/store report"; exit 1; }
echo "$TEXT" | grep -q "count = 2"           || { echo "FAIL: store count not 2";  exit 1; }
echo "$TEXT" | grep -q "layout = singleton"  || { echo "FAIL: singleton layout not derived"; exit 1; }
echo "$TEXT" | grep -q "watchers = 1"        || { echo "FAIL: watcher count not derived"; exit 1; }

echo "=== koruc input.k explain json (nested, typed) ==="
JSON=$(koruc input.k explain json 2>&1 | grep -E '^\{')
echo "$JSON"
# nested by store; count is a typed integer; global has one watcher
echo "$JSON" | grep -q '"global":{"layout":"singleton"' || { echo "FAIL: per-store nesting missing"; exit 1; }
echo "$JSON" | grep -q '"count":2'                       || { echo "FAIL: count not typed integer";  exit 1; }

echo "=== PASS: std/store explainer reports derived decisions ==="
