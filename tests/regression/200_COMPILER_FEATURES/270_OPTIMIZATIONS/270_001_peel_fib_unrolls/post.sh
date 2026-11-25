#!/bin/bash
# Pin: bounded recursive unrolling fires on the fib shape at D=2.
# Residual self-call census: s^(D+1) = 2^3 = 8 inside the impl + 1 external
# call in the main flow = 9 `fib_event.handler(` sites total (baseline
# untransformed shape has 3). Substituted guards (`n - 1` inside the `< 2`
# test) are the substitution fingerprint — the source body only compares
# bare `n`.
set -e
sites=$(grep -o 'fib_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 9 ]; then
    echo "FAIL: expected 9 fib_event.handler( sites (8 residual + 1 main) at D=2, found $sites — unroll pass did not fire or depth is wrong"
    exit 1
fi
if ! grep -qE 'n - 1[^<]*< 2|n - 1\) < 2|\(n - 1\) < 2' output_emitted.zig; then
    echo "FAIL: no parameter-substituted guard (n - 1 ... < 2) — body copies were not substituted"
    exit 1
fi
