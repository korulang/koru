#!/usr/bin/env bash
# wm adapter for koru — the world-model CLI's entry into this repo pair.
#
# Contract (see `wm help`): the exit code speaks for the INSTRUMENT (did
# the wall run and produce a snapshot?), stdout reports the WORLD (pass
# rates, counts). A healthy instrument loudly reporting 45 red tests is a
# GREEN run.
#
# Full, unfiltered runs only — koru's own meaningfulness rule: only
# comparable observations enter the time series (run_regression.sh
# snapshots exclusively on full, non-smoke, unfiltered runs).
set -u
cd "$(dirname "$0")/.."

# node does the stat — `stat` flag dialects (GNU vs BSD) differ across
# machines and this repo runs on both.
mtime() { node -e 'try{process.stdout.write(String(Math.floor(require("fs").statSync(process.argv[1]).mtimeMs)))}catch{process.stdout.write("0")}' "$1"; }

before=$(mtime test-results/latest.json)

# START beat — a purely-visual trace onto the Cordial board that the suite is now
# running (so an empty board reads as idle, not mid-run). Best-effort; keeps
# run_regression.sh dumb — the adapter brackets the run, the runner never learns.
if command -v bun >/dev/null 2>&1; then
  bun wm/producer/cordial.ts --start >&2 || true
fi

# Time the wall so the suite's OWN runtime becomes a measured world-signal
# (scraped by `wm run --json`, pumped to the Cordial bus by wmbus.ts). Capture
# real/user/sys seconds; run_regression's own stderr shares the temp file, so we
# pluck the "R U S" float-triple `time` appends after the command exits.
TIMEFORMAT='%R %U %S'
_timefile=$(mktemp)
{ time ./run_regression.sh; } 2>"$_timefile"
wall_exit=$?
read -r _wall _user _sys < <(grep -E '^[0-9]+\.[0-9]+ [0-9]+\.[0-9]+ [0-9]+\.[0-9]+$' "$_timefile" | tail -1)
rm -f "$_timefile"
after=$(mtime test-results/latest.json)

if [ "$after" -le "$before" ]; then
  echo "wm-adapter: FAIL — wall exited ${wall_exit} and no snapshot was written (instrument fault)" >&2
  exit 1
fi

# Measured world-signals — the suite's OWN runtime health, as cards on the bus.
# Emit RAW numbers only (wall, cpu, test count); efficiency = cpu/wall is the
# engine's to derive (dumb signal, smart engine). cpu = user+sys. Until now the
# adapter emitted no machine signals at all — which is exactly why a 6x parallel
# regression could hide in plain sight (see fix 79d1e9c9).
# Guard on a real parse: a bogus 0 is worse than a missing signal, so warn loudly
# rather than emit a fabricated number if the wall time couldn't be read.
if [[ "${_wall:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  _cpu=$(awk "BEGIN{printf \"%.2f\", ${_user:-0}+${_sys:-0}}")
  _tests=$(node -e 'process.stdout.write(String(require("./test-results/latest.json").summary.total||0))')
  echo "signal regression_wall_seconds ${_wall} s"
  echo "signal regression_cpu_seconds ${_cpu} s"
  echo "signal regression_tests ${_tests:-0}"
else
  echo "wm-adapter: WARN — could not parse suite wall time; no timing signal emitted" >&2
fi

node -e '
  const s = require("./test-results/latest.json").summary;
  console.log(
    `wm-adapter: snapshot saved — inScope ${s.inScope}, passed ${s.passed}, ` +
    `failed ${s.failed}, todo ${s.todo}, passRate ${s.passRate}% ` +
    `(world state; wall exit '"${wall_exit}"')`
  );
'

# World-model faucet — surface the per-test FLIPS + the whole-run VERDICT onto the
# Cordial signals bus (koru.regression.test + test-health). PURE EXHAUST, kept OUT
# of run_regression.sh so the runner stays dumb (see wm/producer/): the adapter is
# the one layer that knows about both the suite and the world. The scalar timing
# signals above ride wm→wmbus; the rich per-test + categorical verdict cards need a
# direct POST, so the producer sends them itself. Best-effort — a down bus must
# never red this instrument; output to stderr so `wm run` scrapes only signal lines.
if command -v bun >/dev/null 2>&1; then
  bun wm/producer/cordial.ts >&2 \
    || echo "wm-adapter: NOTE — cordial world-model faucet skipped (bus down or producer error)" >&2
fi
exit 0
