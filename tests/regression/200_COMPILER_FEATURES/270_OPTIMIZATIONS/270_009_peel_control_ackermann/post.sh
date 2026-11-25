#!/bin/bash
# Pin (CONTROL): ackermann-shaped recursion must NOT be unrolled. The pass
# refuses (no param decreases on all 3 self-call sites), so the emitted
# shape stays the flat segment machine: __koru_seg_eval present and exactly
# 1 `ack_event.handler(` site — the external call; the impl carries zero
# direct self-calls under segment lowering. If the pass fired, inline_body
# would bypass segment lowering and the census/guards would change.
set -e
if ! grep -q '__koru_seg_eval' output_emitted.zig; then
    echo "FAIL: __koru_seg_eval absent — ackermann did not keep the segment-machine lowering (pass may have transformed it)"
    exit 1
fi
sites=$(grep -o 'ack_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 1 ]; then
    echo "FAIL: expected baseline 1 ack_event.handler( site under segment lowering, found $sites — ackermann was transformed"
    exit 1
fi
if grep -qE 'm - 1\)?.*== 0|n - 1\)?.*== 0|\(m - 1\) == 0|\(n - 1\) == 0' output_emitted.zig; then
    echo "FAIL: parameter-substituted guard present — ackermann was unrolled"
    exit 1
fi
