#!/bin/bash
# Pin: collapse-recursion fires R2a on loop-k — additive Faulhaber under
# modulus. Marker + i128 widen fingerprint + snake residual loop_k_event.
set -e
if ! grep -q '__koru_collapse_r2' output_emitted.zig; then
    echo "FAIL: __koru_collapse_r2 marker absent — collapse pass did not fire on loop-k"
    exit 1
fi
if grep -q 'loop-k_event' output_emitted.zig; then
    echo "FAIL: unmangled kebab residual loop-k_event present — parses as subtraction"
    exit 1
fi
if ! grep -q 'i128' output_emitted.zig; then
    echo "FAIL: i128 widen absent — additive mod-form not emitted"
    exit 1
fi
