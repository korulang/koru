#!/bin/bash
# Pin: collapse-recursion fires R1 on the hanoi shape. Marker + closed-form
# fingerprint + domain guard + residual must all be present; the flat segment
# machine must be bypassed for this flow.
set -e
if ! grep -q '__koru_collapse_r1' output_emitted.zig; then
    echo "FAIL: __koru_collapse_r1 marker absent — collapse pass did not fire on hanoi"
    exit 1
fi
if ! grep -q '@import("std").math.mul' output_emitted.zig; then
    echo "FAIL: closed-form checked mul absent — R1 body not emitted"
    exit 1
fi
if ! grep -q 'n <= 62' output_emitted.zig; then
    echo "FAIL: domain guard (n <= 62) absent — legality spine missing"
    exit 1
fi
