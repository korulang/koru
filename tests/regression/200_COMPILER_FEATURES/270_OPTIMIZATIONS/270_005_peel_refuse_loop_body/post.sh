#!/bin/bash
# Pin: recursion containing a `for` loop with a console effect must NOT be
# unrolled — the emitted shape stays at the baseline 3 `fibloop_event.
# handler(` sites (2 self + 1 main) with no parameter-substituted guards.
# Refusal is silent: the program still runs and prints correctly.
set -e
sites=$(grep -o 'fibloop_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 3 ]; then
    echo "FAIL: expected baseline 3 fibloop_event.handler( sites, found $sites — loop/effect-bearing recursion was transformed"
    exit 1
fi
if grep -qE 'n - 1\)?.*< 2|\(n - 1\) < 2' output_emitted.zig; then
    echo "FAIL: parameter-substituted guard present — loop/effect-bearing recursion was unrolled"
    exit 1
fi
