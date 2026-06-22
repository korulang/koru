# register_machine

**Question:** does Koru's array-threading idiom — threading invariant `[8]i64`
payloads through a by-value event `Input` across recursion (the AoC day18/day23
pattern) — match naive Rust, or does the per-call payload copy cost?

The `run` event is the exact day23 register-machine decoder: it decodes one
instruction per call and recurses, threading `ops` / `regs` / `offs` (`[8]i64`
each) through its by-value `Input`. The program is 7 `inc a` instructions, so
each run is a bounded depth-7 recursion that executes the full decode arithmetic
every step. The outer `~for` drives N runs and sums the results. Pure-Koru hot
path; the only zig glue is argv-read and the accumulator (off the measured path).

The Rust baseline writes the same machine the natural way: arrays borrowed by
reference, inner step a plain loop. Identical work, identical output.

## NOT a valid head-to-head — this benchmark folds. See the blog.

This workload was the *motivating measurement* for tail-self-continuation loop
lowering (`emitter_helpers.zig` "Tail self-continuation loop lowering", landed
`c7337761` 2026-06-19). Its history, in two acts:

**Act 1 — pre-lowering (HEAD ~1c822cae, measured 2026-06-18 22:41).** The
emitted `run` handler did a 224-byte copy of the whole by-value `Input` at entry
plus 64-byte `[8]i64` copies per call, in a non-tail recursive call with a
1424-byte frame — LLVM could not elide the copy. Measured **koru ~1503ms vs rust
~577ms, ~2.6× slower.**

**Act 2 — post-lowering (current HEAD).** The self-tail-call is now lowered to a
`while (true)` loop (no per-iteration aggregate copy), which made the inner
decoder *visible to the optimizer* — and it **constant-folds**. koru now runs at
**~33ms** (raw binary ~10ms) vs rust **~557ms**. But that ~16× is NOT a
throughput win: koru folds the inner decode to a closed form, the naive Rust
baseline (arrays borrowed by ref, plain loop) does not. Write the equivalent
Rust as a `const` and it folds to ~10ms too.

**So this is no longer a koru-vs-rust race in either direction** — which is why
it is excluded from the world-model perf grid (no `results/register_machine.csv`).
The real story is *foldability*, told in full in the blog post
**"The Recursion That Was a Loop"** (`/blog/recursion-that-was-a-loop`,
2026-06-19). The genuine throughput win the lowering buys — **~3× when folding
is impossible** — needs a folding-impossible variant (program fed from argv) to
measure honestly; that variant is not yet built.
