#!/bin/bash
# Pin (CONTROL): tak-shaped recursion must NOT be unrolled — no param
# decreases on every self-call site (args permute across positions and the
# dependent call has none). The emitted shape stays the flat segment
# machine: __koru_seg_eval present and exactly 1 `tak_event.handler(` site
# — the external call. If the pass fired, inline_body would bypass segment
# lowering and the census would change.
set -e
if ! grep -q '__koru_seg_eval' output_emitted.zig; then
    echo "FAIL: __koru_seg_eval absent — tak did not keep the segment-machine lowering (pass may have transformed it)"
    exit 1
fi
sites=$(grep -o 'tak_event\.handler(' output_emitted.zig | wc -l | tr -d ' ')
if [ "$sites" -ne 1 ]; then
    echo "FAIL: expected baseline 1 tak_event.handler( site under segment lowering, found $sites — tak was transformed"
    exit 1
fi
