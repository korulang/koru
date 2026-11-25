#!/bin/bash
# Pin: collapse-recursion fires B1 fast-doubling on fib. Marker + @clz bit-scan
# fingerprint prove the O(log n) body emitted, not the tree recursion.
set -e
if ! grep -q '__koru_collapse_b1_fib' output_emitted.zig; then
    echo "FAIL: __koru_collapse_b1_fib marker absent — collapse pass did not fire on fib"
    exit 1
fi
if ! grep -q '@clz' output_emitted.zig; then
    echo "FAIL: fast-doubling bit scan (@clz) absent — B1 body not emitted"
    exit 1
fi
