#!/usr/bin/env bash
# wm native PROBE — koru pass-floor surprise.
#
# The lightest governed instrument (see `wm help`): one cheap measurement, no
# suite run. It reads the latest regression snapshot already on disk and emits
# the "passing vs expected" aggregate as WORLD signals — the exact thing a
# world-model should hold (the rollup, not the 866 atoms).
#
# The GOAL is every in-scope test passing (gap = 0). The live `gap` IS the
# surprise: how far the suite sits from its own setpoint. Exit code speaks for
# the INSTRUMENT (could we read a snapshot?); signals speak for the WORLD.
set -u
cd "$(dirname "$0")/../.."  # repo root

SNAP="test-results/latest.json"
if [ ! -f "$SNAP" ]; then
  echo "probe_pass_floor: FAIL — no $SNAP (instrument fault: nothing has snapshotted yet)" >&2
  exit 2
fi

node -e '
  const s = require("./test-results/latest.json").summary;
  const gap = s.inScope - s.passed;
  console.log(`signal passed ${s.passed}`);
  console.log(`signal expected ${s.inScope}`);
  console.log(`signal gap ${gap}`);
  console.log(`signal pass_rate ${s.passRate}`);
  console.log(`probe_pass_floor: ${s.passed}/${s.inScope} passing (${s.passRate}%) — goal ${s.inScope}/${s.inScope}, gap ${gap} below setpoint (the surprise)`);
'
exit 0
