#!/bin/bash
# Pin (RE-PINNED for collapse-before-unroll ordering): collapse-recursion
# runs before unroll-recursion in elaborate, so this shape collapses to a
# closed form FIRST — the __koru_collapse_r1 marker must be present and
# the __koru_unroll_ machine must be absent. This pins ORDERING, not just
# collapse correctness (270_013-018 own that). expected.txt proves the
# collapse preserves semantics.
set -e
if ! grep -q '__koru_collapse_r1' output_emitted.zig; then
    echo "FAIL: __koru_collapse_r1 marker absent — collapse did not fire before unroll"
    exit 1
fi
if grep -q '__koru_unroll_' output_emitted.zig; then
    echo "FAIL: __koru_unroll_ machine present — unroll fired on a collapse-admitted shape (ordering violated)"
    exit 1
fi
