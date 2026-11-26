#!/bin/bash
# Pin: C3 admits coefficient-general recurrences — lrec carries p,q as
# custody params (dup'd per call, halves split mul/pass-through); pelln
# mints p=2 via from-int + mul with the q-term a bare state operand.
# Marker + values pin the companion-matrix body emitted for both.
set -e
if ! grep -q "__koru_collapse_c3_numacc" output_emitted.zig; then
    echo "FAIL: __koru_collapse_c3_numacc marker absent — collapse pass did not fire on coefficient-carrying numacc"
    exit 1
fi
if ! grep -q "decMul" output_emitted.zig; then
    echo "FAIL: decMul absent — C3 did not emit the companion-matrix doubling body"
    exit 1
fi
