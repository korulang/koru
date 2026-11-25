#!/bin/bash
# Pin: bounded recursive unrolling fires on the hanoi shape at D=2.
# Residual self-call census: s^(D+1) = 8 inside the impl + 1 external call
# in the main flow = 9 `hanoi_event.handler(` sites. Substituted guards
# (`n - 1` inside the `== 0` test) prove parameter substitution — the
# source body only compares bare `n`. The dependent sibling-fed arg
# (`acc: h + 1`) must survive substitution intact: semantics are pinned
# by expected.txt (hanoi(4,0) = 15).
set -e
sites=$(grep -o 'hanoi_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 9 ]; then
    echo "FAIL: expected 9 hanoi_event.handler( sites (8 residual + 1 main) at D=2, found $sites — unroll pass did not fire or depth is wrong"
    exit 1
fi
if ! grep -qE 'n - 1\)?.*== 0|\(n - 1\) == 0' output_emitted.zig; then
    echo "FAIL: no parameter-substituted guard (n - 1 ... == 0) — body copies were not substituted"
    exit 1
fi
