#!/bin/bash
# Pin: bounded recursive unrolling fires on the pascal/binom shape at D=2.
# Residual self-call census: s^(D+1) = 8 inside the impl + 1 external call
# in the main flow = 9 `binom_event.handler(` sites (baseline untransformed
# shape has 3). Substituted guards — `k - 1` / `n - 1` expressions inside
# the `== 0` / `== n` tests — are the substitution fingerprint.
set -e
sites=$(grep -o 'binom_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 9 ]; then
    echo "FAIL: expected 9 binom_event.handler( sites (8 residual + 1 main) at D=2, found $sites — unroll pass did not fire or depth is wrong"
    exit 1
fi
if ! grep -qE 'k - 1\)?.*== 0|\(k - 1\) == 0' output_emitted.zig; then
    echo "FAIL: no parameter-substituted guard (k - 1 ... == 0) — body copies were not substituted"
    exit 1
fi
