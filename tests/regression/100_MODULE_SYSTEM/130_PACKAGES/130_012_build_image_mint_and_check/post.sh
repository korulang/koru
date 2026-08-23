#!/bin/bash
# Pins the minted build-image lifecycle. The body compiles clean; this drives
# the COMMAND half — the half that would go green while answering "nothing
# sealed" if it were broken. Five assertions:
#   1. `image mint` seals and reports a closure.
#   2. `image check` matches the mint (clean pipeline green).
#   3. `image mint` again REFUSES — re-minting is anomalous, not routine.
#   4. `image mint --force` explicitly re-seals (the one deliberate escape).
#   5. After a drift, `image check` REFUSES and names the closure diff.

set -e
K="$KORU_INPUT"

# The command writes build.image in cwd; run in the harness's cwd (the test dir)
# so all five steps share one manifest. KORU_INPUT is the bare filename.

# Each `koruc` invocation below that is EXPECTED to fail (re-mint on an existing
# image, check-on-drift) must not trip `set -e` — so their command substitutions
# end with `|| true`. The assertions that follow inspect the captured output,
# which is the real verdict; the exit code only matters where we probe it.
OUT=$(koruc "$K" image mint 2>&1) || true
if ! echo "$OUT" | grep -q "Minted build image: build.image"; then
    echo "✗ mint did not report a sealed image"
    echo "$OUT" | tail -8
    exit 1
fi

if [ -f build.image ]; then
    : 
else
    echo "✗ mint did not write build.image"
    exit 1
fi

OUT=$(koruc "$K" image check 2>&1) || true
if ! echo "$OUT" | grep -q "matches the live closure"; then
    echo "✗ check did not confirm a clean match"
    echo "$OUT" | tail -8
    exit 1
fi

OUT=$(koruc "$K" image mint 2>&1) || true
if echo "$OUT" | grep -q "Minted build image"; then
    echo "✗ re-mint was allowed — re-minting must be anomalous"
    echo "$OUT" | tail -8
    exit 1
fi
if ! echo "$OUT" | grep -q "Re-minting is anomalous"; then
    echo "✗ re-mint refused, but the refusal did not name the anomaly"
    echo "$OUT" | tail -8
    exit 1
fi

OUT=$(koruc "$K" image mint --force 2>&1) || true
if ! echo "$OUT" | grep -q "Minted build image"; then
    echo "✗ --force did not explicitly re-seal"
    echo "$OUT" | tail -8
    exit 1
fi

# Drift: flip a declared requirement so the live closure no longer matches the
# just-minted tree. Rewriting the source file here is safe — it is a scratch
# fixture, not a tracked regression input.
sed -i '' 's/"name": "curl"/"name": "jq"/' "$K"

OUT=$(koruc "$K" image check 2>&1) || true
if echo "$OUT" | grep -q "matches the live closure"; then
    echo "✗ check passed on a drifted closure — the seal did not bite"
    echo "$OUT" | tail -8
    exit 1
fi
if ! echo "$OUT" | grep -q "Build closure drifted"; then
    echo "✗ drifted closure refused, but the refusal did not name the drift"
    echo "$OUT" | tail -8
    exit 1
fi

# Restore the fixture so the test is reproducible on re-run.
sed -i '' 's/"name": "jq"/"name": "curl"/' "$K"

echo "PASS: mint → check → re-mint-refused → --force → drift-refused"
exit 0
