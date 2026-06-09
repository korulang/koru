#!/bin/bash
# Structural pin for the NESTED kernel-fusion path (init under a continuation).
# Mirrors 390_090's top-level pin: after fusion folds into `.computed`, the
# consumed `| kernel` continuation must not survive as a dead `.kernel =>` arm
# holding a duplicate of the fused loops.
set -u
fail=0
copies=$(grep -c 'const s = ' output_emitted.zig)
if [ "$copies" -ne 1 ]; then
    echo "FAIL: fused pairwise body emitted ${copies}x (expected 1) — nested fusion left a dead duplicate"
    fail=1
fi
if grep -q '\.kernel =>' output_emitted.zig; then
    echo "FAIL: dead '.kernel =>' arm present — nested path didn't drop the consumed kernel continuation"
    fail=1
fi
exit $fail
