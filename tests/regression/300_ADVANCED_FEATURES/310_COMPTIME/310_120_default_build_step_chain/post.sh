#!/bin/bash
# Each default build step is pinned on its own named artifact, so a regression
# names the link that broke instead of collapsing to a single "output" mismatch.
#
# Runs with cwd = the test directory (regression_lib.sh cd's here), which is also
# the output directory the steps ran in — the same basis, deliberately.

fail() {
    echo "FAIL: $1"
    exit 1
}

# Step 2 of 3 — the stdlib's own `build`: `./zig-out/bin/backend backend_tmp`.
# `backend_tmp` is that script's own output name, so nothing else in the harness
# produces it. This is the step that ran the wrong binary name (`main`) and,
# separately, lost its depends_on to a comma.
#
# This ALSO proves step 1, `compile_backend`, ran — transitively and soundly: the
# script above cannot execute unless `zig build --build-file build_backend.zig`
# already produced `zig-out/bin/backend`. That path is deliberately NOT asserted
# directly, because `zig-out/` is transient here — the harness clears it between
# its own compilation phases, so a direct check passes or fails on harness
# bookkeeping rather than on whether the step ran.
[[ -f backend_tmp ]] || fail "default build did not produce backend_tmp (so compile_backend or build did not run)"

# Step 3 of 3 — this test's `run`, which depends on `build`. Reaching it at all
# means the whole default chain succeeded, in order.
[[ -f chain.log ]] || fail "run step never executed — chain.log not found"

ACTUAL=$(cat chain.log)
EXPECTED="default chain reached run"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    rm -f chain.log
    fail "chain.log mismatch: expected '$EXPECTED', got '$ACTUAL'"
fi

rm -f chain.log
echo "PASS: default chain ran compile_backend -> build -> run in the output directory"
exit 0
