# bare_return

**Question:** does the `-> T` bare-return (single-payload event output) close the
tiny gap vs Rust that the old single-variant union form (`| name T`) left open?

The old form compiled a single-payload event output to a one-variant
`union(enum) { name: T }` — *constructed* at every return and *field-extracted*
at every bind. On a hot path that construct-then-extract dance is overhead LLVM
did not always elide. The `-> T` form emits the payload directly (`Output = T`,
`return value`, `const m = handler(...)`), so the union is structurally gone.

## The workload

A fold-resistant LCG (Knuth MMIX constants) threaded through a single-payload
event on the hot path. `driver`'s native loop fires the `step` effect N times;
each firing resumes with `mix(acc)`, where `mix` is a `-> u64` bare-return event:

```koru
~pub event mix { x: u64 } -> u64
~proc mix|zig { return x *% 6364136223846793005 +% 1442695040888963407; }
...
! step p -> mix(x: p)          // produce-is-the-call: resume with mix(p)
```

LCG mixing is irreducible, so neither koru nor the baselines can constant-fold
it (output differs per N — `result = 13621014012951058945` at N=1e9). The
dependent chain (each step needs the prior `acc`) defeats ILP, so all three run
at ~1 ns/iter — the natural floor for a serial multiply-add recurrence.

`koru` is the bare-return form. `zig` and `rust` are the same LCG loop written
by hand (no event machinery, no union) — the ideal floor.

## Result (Apple Silicon, ReleaseFast / opt-level 3)

Representative (min-of-15, interleaved, n=2e9, post-fix default `a.out`):

| impl            | min (ms) | vs fastest |
|-----------------|----------|------------|
| koru (default)  | 1897.8   | +0.05%     |
| zig (ideal)     | 1900.3   | +0.19%     |
| rust            | 1896.8   | +0.00%     |

Wall-clock is **noise-limited** on this workload: a fully-dependent `madd`
recurrence runs at the hardware latency floor in all binaries, so they are
indistinguishable. Across many interleaved 15–30 round batches the ordering is
not stable — koru, zig, and rust have each been "fastest" or "slowest" in
different runs, all inside a ~0.2–0.5% noise floor (two *identical-code* Zig
binaries differ by that much run-to-run). The koru-vs-ideal difference lives
inside it.

So the honest claim is **parity**, and the *proof* is the machine code, not the
stopwatch:

```
KORU hot loop (default a.out)       IDEAL (zig/rust)
  madd x, x, C1, C2                   madd x, x, C1, C2
  subs cnt, cnt, #1                   subs cnt, cnt, #1
  b.ne top                            b.ne top
```

Identical loop — the bare-return fully inlined, **zero** event/union/wrapper
residue.

### Build-mode fix (what this benchmark uncovered)

The *first* version of this benchmark measured koru **~0.5–0.8% behind**, and
the cause was not the emission — it was the build. koru's backend defaulted the
**output binary to `ReleaseSmall`** (the orphaned default of a removed `--tiny`
flag), so `a.out` was *size*-optimized while zig/rust were ReleaseFast. The
ReleaseSmall loop emitted `sub; cbnz`; ReleaseFast emits `subs; b.ne`. A
genuine silent-perf-degradation — the exact thing the project's "no silent
performance degradation" doctrine targets.

Fixed: koru now defaults the output binary to **ReleaseFast** (the common
no-deps path in `src/main.zig`; the `build:requires` path via
`emitOutputBuildZig` now sets `preferred_optimize_mode = .ReleaseFast`).
`--debug` produces a real Debug build. The numbers above are the post-fix
default `a.out`. (Historical note: even at ReleaseSmall the runtime delta was
inside the noise floor on *this* latency-bound loop — but on a workload where
ReleaseSmall's different inlining / no-vectorization bites, the size-optimized
default would quietly cost speed.)

## Why (the emitted code)

```
            OLD  | out u64                          NEW  -> u64
Output      union(enum) { out: u64 }                u64
return      return .{ .out = x *% C1 +% C2 };       return x *% C1 +% C2;
bind        const m = result_0.out;                 const m = handler(...);   // plain u64
```

The per-iteration construct+extract is gone. The only `union(enum)` left in the
emitted hot path is `driver`'s own multi-branch Output (`! step` + `| done`),
constructed **once** after the loop — off the hot path.

## Build / run

```bash
# koru
cd koru && koruc input.kz -o backend.zig && zig build -Doptimize=ReleaseFast && ./zig-out/bin/backend
./koru/a.out 1000000000
# zig
cd zig && zig build-exe bench.zig -O ReleaseFast -femit-bin=bench && ./bench 1000000000
# rust
cd rust && cargo build --release && ./target/release/bench 1000000000
```

(`koru_old` — the union-form twin — is intentionally absent: a faithful hot-loop
twin requires the deprecated `|>`-resume-after-chain form, which the language no
longer supports. The old emitted shape is shown in the table above instead.)
