#!/bin/bash
# Pins the kernel-fusion DEAD-BRANCH bug.
#
# After kernel:init fuses step/pairwise/self into its own proc and returns
# `.computed`, the CONSUMED `| kernel` continuation must NOT survive in the
# calling flow. Currently the fusion path copies every original continuation
# verbatim (koru_std/kernel.kz:868) and keeps the `kernel` union branch
# (kernel.kz:1006), so flow0 ends up with a dead `.kernel =>` switch arm that
# holds a SECOND, un-fused copy of the pairwise+self loops. Output is still
# correct (expected.txt passes), so only this structural check catches it.
#
# RED until the fusion path strips the consumed kernel continuation + branch.
set -u

fail=0

# 1. The fused pairwise body must be emitted exactly ONCE (inside the init
#    proc), not duplicated into a dead `.kernel` switch arm.
pairwise_copies=$(grep -c 'const dsq = dx\*dx' output_emitted.zig)
if [ "$pairwise_copies" -ne 1 ]; then
    echo "FAIL: pairwise kernel body emitted ${pairwise_copies}x (expected 1) — fusion left a dead duplicate"
    fail=1
fi

# 2. No dead `.kernel =>` switch arm should remain once init returns `.computed`.
if grep -q '\.kernel =>' output_emitted.zig; then
    echo "FAIL: dead '.kernel =>' switch arm present — consumed kernel continuation not stripped"
    fail=1
fi

exit $fail
