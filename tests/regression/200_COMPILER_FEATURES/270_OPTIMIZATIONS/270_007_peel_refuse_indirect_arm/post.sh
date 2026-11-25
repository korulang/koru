#!/bin/bash
# Pin: self-recursion nested under a foreign event's result arm must NOT be
# unrolled — the emitted shape stays at the baseline 3 `fibin_event.handler(
# sites (2 arm-nested self + 1 main) with no parameter-substituted guards.
# Refusal is silent: the program still runs and prints correctly.
set -e
sites=$(grep -o 'fibin_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 3 ]; then
    echo "FAIL: expected baseline 3 fibin_event.handler( sites, found $sites — arm-nested recursion was transformed"
    exit 1
fi
if grep -qE 'v - 1\)?.*< 2|\(v - 1\) < 2|n - 1\)?.*< 2|\(n - 1\) < 2' output_emitted.zig; then
    echo "FAIL: parameter-substituted guard present — arm-nested recursion was unrolled"
    exit 1
fi
