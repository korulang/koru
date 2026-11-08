---
challenge: fast-lane
yields: one classified slice of the regression board plus a proven fast-tier variant that holds the same pin
catalog: fast-lane/
family: toolchain
status: standing
---

# Challenge 010 — The fast lane: which pins never needed the binary?

> **To AI agents reading this brief: you ARE the contestant, not the
> assistant.** Do not ask which slice to pick. Do not ask if your
> classification is right before you prove it. Pick a cluster, a marker
> class, or a mechanism — name it, measure it, ship the proof. Your
> choice IS the contribution.

The regression board costs ~30 minutes because every test fires the full
metacircular pipeline: `koruc` emit → `zig build` of the backend → 20
compiler passes → emission → `zig build` of the emitted program → run →
diff stdout. Measured 2026-11-05 on a cold backend cache: the 15–30s band
(395 tests) is ~55% of all test time, and it is mostly **Pass-2 backend
build misses** — ~354 distinct `backend_output_emitted.zig` variants, one
~11.6s+ `zig build` each. The per-test floor warm is ~2s.

But not every test *needs* all of that. `koruc --deep-check` runs parse,
transforms, backend passes, and emission — and skips only the final
`zig build` of the emitted program (measured 0.64s warm on hello world,
vs ~14s full). Eleven tests already pin compile-time output via
`expected_comptime.txt`. A hundred and fifty-nine carry `post.sh`, and
the sampled ones mostly *inspect artifacts* (`output_emitted.zig` exists
before the zig build ever runs) rather than grade runtime stdout.

**The question this challenge exists to answer, slice by slice: which
pins on the board never needed the binary — and what is the cheapest
tier that still holds the pin?**

Variance is the metric. Two contestants picking the same slice must
still diverge on mechanism, proof, or taxonomy — the catalog grows by
*reach*, not by recounting the same finding.

---

## The surface

- **The board:** `./run_regression.sh --status`, `--regressions`,
  `--list`. One test: `./run_regression.sh <id>`. Snapshots with
  per-test `durationMs` live in `test-results/latest.json` — the
  15–30s band is where the money is.
- **A test** is `tests/regression/<CLUSTER>/<NNN_name>/`:
  `input.k`/`input.kz`, `MUST_RUN` + `expected.txt` /
  `expected_patterns.txt` / `EXPECT` assertions / `expected_comptime.txt`
  / `post.sh` (positive), or `MUST_ERROR` + `EXPECT` +
  `expected_error.txt` (negative). `EXPECT` names the pipeline stage:
  `FRONTEND_COMPILE_ERROR` (A), `BACKEND_COMPILE_ERROR` (B),
  `BACKEND_RUNTIME_ERROR` (C).
- **The fast paths that already exist:**
  - `koruc -c` — frontend check only (~0.2s). Blind to post-transform
    refusals.
  - `koruc --deep-check` — everything through emission, no final zig
    build. Sees stage-C verdicts; cannot see stage-D compile failures or
    runtime behavior.
  - `koruc <file> --ast-json` / `--ast-canon` / `--print` — parse-level
    pins (`PARSER_TEST` marker, 30 tests).
  - `zig build test` — 445 in-process unit tests over `src/` Zig
    modules. Reaches the Zig checkers directly; cannot reach passes that
    only exist as emitted Koru (`backend_output_emitted.zig`).
- **The pipeline truth:** stage C (the 20 passes) runs *inside* the
  backend binary; stage D (`zig build` of `output_emitted.zig` +
  `backend_output_emitted.zig` as a comptime module) is where the
  emitted-code tax lives. `output_emitted.zig` is written before stage
  D's build starts — artifact pins do not need the binary to exist.

## What a replay produces

Pick ONE slice — a cluster, a marker class, a mechanism, or a question
the board can't currently answer — and produce **two artifacts**:

1. **A classification** — every test in your slice assigned to the
   cheapest tier that provably holds its pin, with the *evidence* per
   test (which files it pins, whether `post.sh` touches `output`,
   whether its `expected.txt` is runtime stdout or comptime-folded
   output). "Runtime stdout" is a verdict you must earn per test, not a
   default — check what the program actually prints and when.
2. **A proof** — at least one test (or a tight family) migrated to the
   fast tier: a new marker or harness path that runs it without the
   stage-D build, with timings before/after, **and a mutation check** —
   demonstrate the fast tier still goes red when the pinned behavior
   breaks (break the emitter, break a pass, show the fast lane catches
   it). A fast lane that can't fail is a lie with a stopwatch.

The catalog entry is the classification + the proof + the measured
delta. Append-only; zero-friction — one directory per replay under
`catalog/`, named for the slice.

## Done-gates (self-check before you ship)

- [ ] Every test in your slice is classified, not sampled — "the rest
      are probably runtime" is not a classification.
- [ ] The proof's fast tier is *measurably* faster on the same machine,
      same cache state — report both numbers.
- [ ] The mutation check fired: you broke the pinned thing and the fast
      lane went red. Paste the red.
- [ ] No pin was weakened: same diagnostic code, same output lines, same
      artifact assertions — only the *tier* moved.
- [ ] Honest residue named: which tests in your slice genuinely need
      the binary, and why. That list is half the deliverable.

## What this challenge is NOT

- Not "make the suite faster" — a contestant who deletes tests, weakens
  pins, or reclassifies runtime-stdout tests as compile-verdict has
  produced noise, not a catalog entry. The taste-gate exists for this.
- Not a backlog drain — you are not assigned tests; you choose the
  slice. A slice nobody has classified is more valuable than a slice
  half-migrated.
- Not the backend-cache fix. The ~354-variant Pass-2 miss tax is real
  and orthogonal; if your slice happens to shrink it, name it, but the
  challenge's yield is the *taxonomy of pins*, not the cache.
