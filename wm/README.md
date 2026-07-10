# wm/ — koru's world-model experiment corner

Everything here is the `wm` (world-model toolchain) dogfood material that targets
koru — moved out of 6digit-world on 2026-06-10 so the world's source stays
target-agnostic: **the world knows generic shapes (signals, watcher tiles); the
adapter and artifacts that know koru's layout live with koru.**

- `floats/2026-06-07-transparency/` — the transparency float that discovered 21
  watcher candidates (commission queue, synthesis, raw output). Row #1 became
  `scripts/registry_check.zig`, now blocking in `run_regression.sh`.
- `floats/drain-loop.md` — the three-round cold-room proof of the drain methodology.
- `signal_map.md` — survey of everything koru emits or could emit as faucets
  (originally 6digit-world challenge 004).
- `producer/regression.ts` — the regression WORK faucet: reads
  `test-results/latest.json`, pushes green↔red flips to the world host's Convex
  intake (the dispatch consumer that wakes a fix agent). `bun wm/producer/regression.ts`.
- `producer/cordial.ts` — the regression WORLD-MODEL faucet: reads the same
  `test-results/latest.json`, diffs it against the last run's per-test state
  (local, at `~/.6digit-cordial/koru-regression-state.json` — no Convex), and posts
  onto the **Cordial signals bus** (`:6285/signal`). The run LIFECYCLE, three
  families split by the dumb-signal/smart-engine razor:
    - `koru.regression.run` — a PURELY VISUAL trace beat straight to the board
      (`route: surface` only, no wake/model). `--start` fires it at suite start;
      `--trace "<msg>"` drops a free breadcrumb. A trace log, nothing more.
    - `koru.regression.test` — RAW per-test FLIP cards (`route: surface, wmfx=regression_shape`).
    - `test-health` — the whole-run VERDICT `green|red|regression` (`route: surface, wake`).
  So the suite START, individual test flips, AND the run result all surface to
  Cordial. `wm/run.sh` brackets the run — `--start` before, flips + verdict after —
  so `wm run .` (governed adapter) closes the loop while `run_regression.sh` stays dumb.

Related, already living elsewhere in koru: `scripts/registry_check.zig`,
`scripts/registry_reserved.txt`, `skills/registry-drain/`.
