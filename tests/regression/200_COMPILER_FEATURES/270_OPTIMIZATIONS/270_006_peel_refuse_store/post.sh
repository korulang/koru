#!/bin/bash
# Pin: recursion bearing a store write (std/store:stored inside the
# recursive branch) must NOT be unrolled — the emitted shape stays at the
# baseline 3 `fibs_event.handler(` sites with no parameter-substituted
# guards. Refusal is silent: the program still runs and prints correctly.
set -e
sites=$(grep -o 'fibs_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 3 ]; then
    echo "FAIL: expected baseline 3 fibs_event.handler( sites, found $sites — effect-bearing recursion was transformed"
    exit 1
fi
if grep -qE 'n - 1\)?.*< 2|\(n - 1\) < 2' output_emitted.zig; then
    echo "FAIL: parameter-substituted guard present — effect-bearing recursion was unrolled"
    exit 1
fi
