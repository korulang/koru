#!/bin/bash
# Pin (boundary probe): fib(92) must return the literal 7540113804746346429 —
# the emitted body carries `if (n == 92) return 7540113804746346429;` between
# the n<=91 doubling block and the residual. Without it the doubling overflows
# i64 one step early.
set -e
if ! grep -q '__koru_collapse_b1_fib' output_emitted.zig; then
    echo "FAIL: __koru_collapse_b1_fib marker absent — collapse pass did not fire on fib"
    exit 1
fi
if ! grep -q '== 92) return 7540113804746346429' output_emitted.zig; then
    echo "FAIL: n==92 boundary literal absent — fib(92) would overflow in the doubling"
    exit 1
fi
