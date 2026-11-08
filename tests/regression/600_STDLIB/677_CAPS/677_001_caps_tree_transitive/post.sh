#!/bin/bash
# `caps` census reports every declaration carrying cap(...) entries or
# surface-scan hits; `caps <subject>` walks the impl graph downstream and
# attributes each reached node's declared caps; `explain` carries the
# std/caps section for programs that import it.

set -e

OUT=$(koruc "$KORU_INPUT" caps 2>&1) && RC=0 || RC=$?

[ "$RC" -eq 0 ] \
    || { echo "FAIL: caps exited $RC"; echo "$OUT"; exit 1; }

echo "$OUT" | grep -q 'caps — ' \
    || { echo "FAIL: census header missing"; echo "$OUT"; exit 1; }

# The contract-level entry survives verbatim — `io|network` is ONE entry,
# the payload inside cap(...) is opaque text.
echo "$OUT" | grep -q 'CAP tor input:fetch  io|network' \
    || { echo "FAIL: contract cap entry not censused"; echo "$OUT"; exit 1; }

# Impl procs report declared caps AND scan hits, attributed by target.
echo "$OUT" | grep -q 'CAP proc input:fetch|zig  decl:io  decl:network  scan: std.net. std.time. std.crypto.' \
    || { echo "FAIL: fetch impl caps/scan not reported"; echo "$OUT"; exit 1; }

# churn declares nothing; the scan finds std.fs/std.process in a COMMENT —
# the inferred tier's honest false positive.
echo "$OUT" | grep -q 'CAP proc input:churn|zig  scan: std.fs. std.process' \
    || { echo "FAIL: churn scan hits not reported"; echo "$OUT"; exit 1; }

# Tree mode: job's flow impl reaches fetch — transitivity through wiring.
OUTT=$(koruc "$KORU_INPUT" caps job 2>&1)
echo "$OUTT" | grep -q 'caps tree: input:job' \
    || { echo "FAIL: tree subject header missing"; echo "$OUTT"; exit 1; }
echo "$OUTT" | grep -q 'nodes reached' \
    || { echo "FAIL: node count missing"; echo "$OUTT"; exit 1; }
echo "$OUTT" | grep -q 'contract input:fetch: io|network' \
    || { echo "FAIL: reached contract caps missing"; echo "$OUTT"; exit 1; }
echo "$OUTT" | grep -q 'impl input:fetch|zig: io network' \
    || { echo "FAIL: reached impl caps missing"; echo "$OUTT"; exit 1; }

# A silent reached node is reported, never dropped.
echo "$OUTT" | grep -q 'no declared caps' \
    || { echo "FAIL: silent node not reported"; echo "$OUTT"; exit 1; }

# explain: the std/caps explainer section rides the gather.
OUTE=$(koruc "$KORU_INPUT" explain 2>&1)
echo "$OUTE" | grep -q 'std/caps' \
    || { echo "FAIL: explain missing std/caps section"; echo "$OUTE"; exit 1; }
echo "$OUTE" | grep -q 'declarations_with_caps' \
    || { echo "FAIL: coverage property missing"; echo "$OUTE"; exit 1; }
echo "$OUTE" | grep -q 'cap(...) declarations' \
    || { echo "FAIL: declarations section missing"; echo "$OUTE"; exit 1; }
echo "$OUTE" | grep -q 'surface scan' \
    || { echo "FAIL: inferred scan section missing"; echo "$OUTE"; exit 1; }
