#!/bin/bash
# Pin (CONTROL): the swapped-assignment recurrence must NOT be collapsed —
# no __koru_collapse_ marker may appear in the emitted Zig.
set -e
if grep -q "__koru_collapse_" output_emitted.zig; then
    echo "FAIL: __koru_collapse_ marker present — swapped recurrence was collapsed"
    exit 1
fi
