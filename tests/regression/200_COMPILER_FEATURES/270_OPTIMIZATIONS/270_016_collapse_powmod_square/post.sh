#!/bin/bash
# Pin: collapse-recursion fires R2b on pow-mod. Marker + square-and-multiply
# fingerprint + SNAKE-CASE residual (pow_mod_event, not pow-mod_event) —
# the kebab mangle is the load-bearing detail this pin guards.
set -e
if ! grep -q '__koru_collapse_r2' output_emitted.zig; then
    echo "FAIL: __koru_collapse_r2 marker absent — collapse pass did not fire on pow-mod"
    exit 1
fi
if grep -q 'pow-mod_event' output_emitted.zig; then
    echo "FAIL: unmangled kebab residual pow-mod_event present — parses as subtraction"
    exit 1
fi
if ! grep -q 'pow_mod_event.handler' output_emitted.zig; then
    echo "FAIL: snake residual pow_mod_event.handler absent"
    exit 1
fi
