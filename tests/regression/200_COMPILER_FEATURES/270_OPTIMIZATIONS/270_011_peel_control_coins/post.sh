#!/bin/bash
# Pin (CONTROL): coins/ways-shaped recursion must NOT be unrolled under
# v1 — asymmetric data-dependent decrement plus a foreign coin() call.
# Baseline census: `ways_event.handler(` = 3 (2 self + 1 main),
# `coin_event.handler(` = 1 (the call inside ways). If the pass fired on
# ways the ways census would grow to 9; a v2 lex-measure admission flips
# this pin deliberately, not silently.
set -e
wsites=$(grep -o 'ways_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$wsites" -ne 3 ]; then
    echo "FAIL: expected baseline 3 ways_event.handler( sites, found $wsites — ways was transformed"
    exit 1
fi
csites=$(grep -o 'coin_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$csites" -ne 1 ]; then
    echo "FAIL: expected baseline 1 coin_event.handler( site, found $csites — coin call structure changed"
    exit 1
fi
if grep -qE 'kind - 1\)?.*== 0|amount - [a-z0-9]+\)?.*== 0|\(kind - 1\) == 0' output_emitted.zig; then
    echo "FAIL: parameter-substituted guard present — ways was unrolled"
    exit 1
fi
