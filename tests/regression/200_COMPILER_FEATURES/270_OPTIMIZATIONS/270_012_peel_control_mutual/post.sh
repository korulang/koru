#!/bin/bash
# Pin (CONTROL): mutual recursion must NOT be transformed — neither tor is
# direct self-recursion. Baseline census measured on the current lowering
# (tail-mutual flattens: is_even=1 is_odd=0 handler sites — the parity chain
# runs as loops inside the handler_impls, only the external is-even call
# remains). The pin asserts those counts are UNCHANGED and no
# parameter-substituted guards appear.
set -e
esites=$(grep -o 'is_even_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
osites=$(grep -o 'is_odd_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$esites" -ne 1 ] || [ "$osites" -ne 0 ]; then
    echo "FAIL: mutual handler census changed (is_even=$esites is_odd=$osites, baseline 1/0) — mutual recursion was transformed"
    exit 1
fi
if grep -qE 'n - 1\)?.*== 0|\(n - 1\) == 0' output_emitted.zig; then
    echo "FAIL: parameter-substituted guard present — mutual recursion was unrolled"
    exit 1
fi
