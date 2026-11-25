#!/bin/bash
# Pin (CONTROL): ackermann-shaped recursion must NOT be collapsed. The pass
# refuses (sibling-result bind breaks the measure rule), so no
# __koru_collapse_ marker may appear in the emitted Zig.
set -e
if grep -q '__koru_collapse_' output_emitted.zig; then
    echo "FAIL: __koru_collapse_ marker present — ackermann was collapsed"
    exit 1
fi
