#!/bin/bash
# Pin (CONTROL): recursion interleaved with a foreign call must NOT be
# collapsed — the chain's middle link is not a self-call, so the matchers
# refuse and no __koru_collapse_ marker may appear.
set -e
if grep -q '__koru_collapse_' output_emitted.zig; then
    echo "FAIL: __koru_collapse_ marker present — IO-interleaved recursion was collapsed"
    exit 1
fi
