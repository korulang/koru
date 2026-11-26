#!/bin/bash
# Pin: collapse-recursion fires C3 on the num-custody fib. Marker + a Dec
# parse/format fingerprint prove the limb-add body emitted, not the
# O(n) string round-trip loop.
set -e
if ! grep -q "__koru_collapse_c3_numacc" output_emitted.zig; then
    echo "FAIL: __koru_collapse_c3_numacc marker absent — collapse pass did not fire on num-custody fib"
    exit 1
fi
if ! grep -q "decParse" output_emitted.zig; then
    echo "FAIL: decParse absent — C3 did not emit the parse-once body"
    exit 1
fi
