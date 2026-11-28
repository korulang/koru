#!/bin/bash
# Pin: collapse-recursion fires C3 on the rational-custody fib + pell via the
# kit table — marker + a Rat parse/emit fingerprint prove the limb loop
# emitted, not the O(n) canon round-trip.
set -e
if ! grep -q "__koru_collapse_c3_ratacc" output_emitted.zig; then
    echo "FAIL: __koru_collapse_c3_ratacc marker absent — collapse pass did not fire on rational-custody recurrences"
    exit 1
fi
if ! grep -q "koru_std.koru_rational.kitParse" output_emitted.zig; then
    echo "FAIL: kitParse absent — C3 did not emit the kit decode-once body"
    exit 1
fi
