---
type: belief
id: frag-a-suite-speed-dial-lives-in-the-harness-not-the-judged-artifact
provenance: KORU_OPTIMIZE wiring on quantity-numbers — 615_NUM measured 3:53 Debug vs 1:48 ReleaseFast at -j12, and a parallel ReleaseFast backend stampede that starved every worker past the 600s timeout
ts: 2026-11-22
tags: [koru, regression, suite-cost, ci, caching]
---

# A suite's speed dial lives in the harness binaries, not the judged artifact (belief)

Three binaries participate in a regression test, and only one of them is
what the test is *about*: the emitted program. koruc's own optimize mode
and the backend's are infrastructure — the verdict the suite hands down
identical either way. Measured on 615_NUM (76 tests, -j12, 2026-11-22):
a Debug koruc board costs 3:53; the same board under `KORU_OPTIMIZE=
ReleaseFast` costs 1:48, because the frontend's stdlib analysis — not
the `zig build` of `output_emitted.zig` — is the dominant per-test term
(~36s of ~44s on the heaviest quantity test). The emitted program stays
`-O Debug` in both cases, which is what the suite should judge; koruc's
Debug safety checks are a different test entirely (`zig build test`,
fuzzing), not something the board needs to pay for 76 times.

The dial has a sharp edge that decided the shape of the wiring: a
ReleaseFast *backend* build cannot finish inside the per-test 600s
timeout. One cold LLVM-opt backend build ran ~5:47 solo; under a
parallel wave, twelve workers each missed the shared cache, starved
each other, and all hit the timeout — and since a timed-out build
stores nothing, the stampede repeats on every retry. So `KORU_OPTIMIZE`
scopes to the compiler binary alone, and the parallel path now runs the
first compilable test serially before `xargs` fans out: one warm-up
fills the content-keyed backend cache for the whole wave, cold-start
stampede included in the Debug case it might someday bite.

Pairs with [[frag-a-backend-cache-keyed-on-mtime-can-serve-poison]] —
the cache already keys on the backend's linked closure; the stampede
was not a key defect but an absence of a serial cold-start, which is
why the fix lives in dispatch order, not in the key.
