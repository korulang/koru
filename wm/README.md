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
- `producer/` — the regression WORK faucet: reads `test-results/latest.json`,
  pushes green↔red flips to the world host's Convex intake.
  `cd wm/producer && bun install && bun run push`.

Related, already living elsewhere in koru: `scripts/registry_check.zig`,
`scripts/registry_reserved.txt`, `skills/registry-drain/`.
