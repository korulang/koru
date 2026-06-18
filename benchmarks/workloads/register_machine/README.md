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

## Finding (HEAD ~1c822cae, ReleaseFast, Apple Silicon)

| language | n | wall_ms |
|---|---|---|
| koru | 20M | ~1503 |
| rust | 20M | ~577 |

**Koru ~2.6× slower than naive Rust.** At ReleaseFast the emitted `run` handler
does a 224-byte copy of the whole `Input` at entry plus 64-byte `[8]i64` copies
per call (10 memcpy-stub calls per invocation), in a non-tail recursive call with
a 1424-byte frame — LLVM does not elide the copy. This is the motivating
measurement for the escape-driven by-`*const` event-Input ABI (the "no silent
performance degradation" arc): the target is Rust parity.

A payload-copy-dominated microbench (near-zero work per step) shows the same
idiom ~71× slower — that's the amplified upper bound; the 2.6× here is the
representative number with real per-step work.
