---
type: belief
id: frag-profiler-pins-race-on-global-trace-path
provenance: bettermaker pass 3, 2026-09-01 — parallel oracle 2/5 post-validation red; snapshot fix greens 8/8
ts: 2026-09-01
---

# Profiler pins race on a global trace path unless the harness snapshots per test (belief)

Every profiler regression pin that validates Chrome trace output runs the program
with `--profile`, which writes `/tmp/koru_profile.json`. Six pins share that
path. When `./run_regression.sh` runs them in parallel, another worker's run
overwrites the file before `post.sh` reads it — measured 2/5 `post-validation`
failures with no compiler defect.

The oracle honestly worked around this with `--parallel 1`. That is not a product
fix; it hides that parallel regression is the default and profiler pins are not
isolated.

**Fix (harness-level, 2026-09-01):** `regression_lib.sh` copies
`/tmp/koru_profile.json` to `$test_dir/koru_profile.snapshot.json` immediately
after `./output` when the test has a `post.sh`. Each profiler `post.sh` prefers
the snapshot, falling back to `/tmp` for manual runs.

Measured: six profiler controls + full 8-control oracle pass with default
parallelism. `./scripts/bettermaker_profiler_oracle.sh` no longer forces
`--parallel 1`.

Still open: per-test profile output path in `koru_std/profiler.kz` (env var) —
would remove the global entirely; snapshot is sufficient for regression honesty.
