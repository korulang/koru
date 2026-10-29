#!/bin/bash
# `koruc explain` gathers [explainer] reports: std/store's `elaborated`
# section runs process_all_transforms on a clone and prints the items the
# transforms minted — the dissolved site marker, the rewritten site
# calls, the SoA cell, and the `__store_*` vocabulary — plus the one
# minted flow the canonical printer cannot spell.
set -e

echo "=== koruc explain (text) ==="
TEXT=$(koruc "$KORU_INPUT" explain 2>&1)
echo "$TEXT"
echo "$TEXT" | grep -q "📖 std/store"                                  || { echo "FAIL: store report missing";        exit 1; }
echo "$TEXT" | grep -q "elaborated -- input:body"                     || { echo "FAIL: elaborated section missing";   exit 1; }
echo "$TEXT" | grep -qE "the pass left [0-9]+ item\(s\)"              || { echo "FAIL: minted count missing";         exit 1; }

echo "=== the sites, rewritten ==="
echo "$TEXT" | grep -qE "site input\.k:[0-9]+ -- .std/store:new. dissolved to emit-only IR" || { echo "FAIL: dissolved new-site row missing"; exit 1; }
echo "$TEXT" | grep -q "// std/store: plural store 'body' created"    || { echo "FAIL: marker comment not printed";   exit 1; }
echo "$TEXT" | grep -qE "site input\.k:[0-9]+ -- .std/store:insert. became:" || { echo "FAIL: insert site row missing";   exit 1; }
echo "$TEXT" | grep -q "__store_insert_body(left: 10, right: 20"      || { echo "FAIL: insert rewrite not printed";   exit 1; }
echo "$TEXT" | grep -qE "site input\.k:[0-9]+ -- .std/store:query. became:" || { echo "FAIL: query site row missing";    exit 1; }
echo "$TEXT" | grep -q "__store_sweeprun_body_L"                      || { echo "FAIL: sweeprun call not printed";    exit 1; }

echo "=== the minted vocabulary ==="
echo "$TEXT" | grep -q "the SoA cell"                                 || { echo "FAIL: cell row missing";             exit 1; }
echo "$TEXT" | grep -q "var __koru_store_body"                        || { echo "FAIL: cell decl not printed";        exit 1; }
echo "$TEXT" | grep -q "tor input:__store_insert_body"                || { echo "FAIL: insert tor not printed";       exit 1; }
echo "$TEXT" | grep -q "tor input:__store_apply_body"                 || { echo "FAIL: apply tor not printed";        exit 1; }
echo "$TEXT" | grep -q "input:__store_write_body = input:__store_apply_body" || { echo "FAIL: write subflow not printed"; exit 1; }
echo "$TEXT" | grep -q "proc input:__store_apply_body|zig"            || { echo "FAIL: apply proc not printed";       exit 1; }

echo "=== the pinned finding: a minted flow the printer cannot spell ==="
echo "$TEXT" | grep -qE "flow __store_sweepbody_body_L[0-9]+.*: the printer cannot spell it" || { echo "FAIL: unspellable sweepbody row missing"; exit 1; }

echo "=== PASS: explain prints the transform's own output ==="
