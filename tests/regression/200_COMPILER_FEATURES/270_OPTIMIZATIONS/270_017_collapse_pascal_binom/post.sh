#!/bin/bash
# Pin: collapse-recursion fires B2 on binom. Marker __koru_collapse_b2_binom
# plus the factorial-quotient product fingerprint (__div@/mul chain).
set -e
if ! grep -q '__koru_collapse_b2_binom' output_emitted.zig; then
    echo "FAIL: __koru_collapse_b2_binom marker absent — collapse pass did not fire on binom"
    exit 1
fi
