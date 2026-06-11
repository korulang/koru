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
./run_regression.sh
wall_exit=$?
after=$(mtime test-results/latest.json)

if [ "$after" -le "$before" ]; then
  echo "wm-adapter: FAIL — wall exited ${wall_exit} and no snapshot was written (instrument fault)" >&2
  exit 1
fi

node -e '
  const s = require("./test-results/latest.json").summary;
  console.log(
    `wm-adapter: snapshot saved — inScope ${s.inScope}, passed ${s.passed}, ` +
    `failed ${s.failed}, todo ${s.todo}, passRate ${s.passRate}% ` +
    `(world state; wall exit '"${wall_exit}"')`
  );
'
exit 0
