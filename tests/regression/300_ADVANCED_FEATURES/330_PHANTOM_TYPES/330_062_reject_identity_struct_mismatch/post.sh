#!/bin/bash
# Custom validation for 330_062.
#
# The proc body declares `~event connect | ok Connection[open!]` (identity
# branch), but `~proc connect` returns `.{ .ok = .{ .conn = ... } }` — a
# struct shape that doesn't match the declared identity-branch payload type.
#
# Per koru/CLAUDE.md "Koru is emit-only with the host language," shape_checker
# does NOT introspect proc body Zig. So the diagnostic for this mismatch must
# come from downstream: when c1 is bound from the malformed return, its tracked
# phantom state is inconsistent, and the phantom checker catches it as soon as
# c1.conn is passed to `begin`.
#
# This script verifies that:
#   1. The compiler produced KORU-coded errors (didn't crash with a Zig stack
#      trace from a segfault on the malformed state propagation path).
#   2. The diagnostic identifies the bound binding's bad shape (phantom state
#      mismatch / not-discharged), proving Koru caught the mismatch downstream
#      rather than letting it propagate to Zig.
#   3. The error message is meaningful (mentions the bound name and what's
#      wrong), not just a generic panic.
#
# A regex pin in expected_patterns.txt was the old approach. It demanded the
# error mention "identity" and come from shape_checker — both unreachable under
# the emit-only principle. post.sh expresses the actual invariant instead.

set -e

[ -s backend.err ] || { echo "FAIL: backend.err is missing or empty"; exit 1; }

# Must produce a KORU error code, not a raw Zig stack trace from a crash.
if ! grep -qE 'error\[KORU[0-9]+\]' backend.err; then
    echo "FAIL: no KORU error code in backend.err — compiler may have crashed"
    cat backend.err
    exit 1
fi

# Must not contain segfault / panic / general protection markers.
if grep -qE 'general protection exception|panic:|Segmentation fault' backend.err; then
    echo "FAIL: compiler crashed instead of producing a clean diagnostic"
    cat backend.err
    exit 1
fi

# Must identify the bound-binding shape mismatch. Phantom checker catches this
# as either "no tracked phantom state" on the argument or "not discharged" on
# the bound resource — either is acceptable evidence the mismatch was caught.
if ! grep -qE 'no tracked phantom state|was not discharged' backend.err; then
    echo "FAIL: diagnostic doesn't reference the bound-shape mismatch"
    cat backend.err
    exit 1
fi

# Must reference at least one of the bindings from the test flow.
if ! grep -qE "'(c1|c2|conn|tx)'" backend.err; then
    echo "FAIL: diagnostic doesn't name any of the involved bindings"
    cat backend.err
    exit 1
fi

echo "PASS: malformed identity-branch return diagnosed downstream without segfault"
exit 0
