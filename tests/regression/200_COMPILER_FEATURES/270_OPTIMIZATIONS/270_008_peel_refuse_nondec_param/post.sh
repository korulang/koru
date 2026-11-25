#!/bin/bash
# Pin: recursion where no single param decreases on EVERY self-call site
# (alternating n/k decrements) must NOT be unrolled — the emitted shape
# stays at the baseline 3 `fnd_event.handler(` sites (2 self + 1 main) with
# no parameter-substituted guards. Refusal is silent: the program still
# runs and prints correctly.
set -e
sites=$(grep -o 'fnd_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 3 ]; then
    echo "FAIL: expected baseline 3 fnd_event.handler( sites, found $sites — non-decreasing-param recursion was transformed"
    exit 1
fi
if grep -qE 'n - 1\)?.*< 2|k - 1\)?.*< 0|\(n - 1\) < 2|\(k - 1\) < 0' output_emitted.zig; then
    echo "FAIL: parameter-substituted guard present — non-decreasing-param recursion was unrolled"
    exit 1
fi
