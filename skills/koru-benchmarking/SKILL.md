---
name: koru-benchmarking
description: DRAFT. The method for making Koru fast — NAIVE CODE => OPTIMAL BINARIES. Use when a benchmark/kernel is slow and you need to close a performance gap: diagnose from the Koru code, escalate to emitted-Zig backport, or introduce a high-performance primitive — with the optimization always landing in the toolchain, never in the .k. Also the discipline referenced by the compute-kernel gap-mining challenge for commissioned perf runs.
---

# Koru benchmarking — NAIVE CODE => OPTIMAL BINARIES

> **DRAFT.** The spine is settled; the tooling references are real. Refine against use.

The whole thesis in four words: **naive code compiles to optimal binaries.** The
programmer writes the obvious, faithful, un-tricky thing; the *compiler* earns the
speed. A benchmark that is slow is not a call to make the `.k` cleverer — it is a
gap in the toolchain, and closing it is the work.

## The sacred invariant (read this before touching anything)

**The Koru source stays naive. The optimization ALWAYS lands in the toolchain —
the emitter or a library primitive — NEVER in the `.k`.** If the only way to go
fast is to un-naive the kernel (hand-roll the loop, pre-bake the answer, special-
case the input), you have not done the work; you have faked it. That is the perf-
side twin of "never fake the artifact with a script," and it is faithfulness fraud
against the benchmark. The compiler has to earn every millisecond. A green earned
by contorting the source is worth less than the red it replaced.

## The escalation ladder (reach for them in order)

**Move 1 — Diagnose from the Koru code.** Most of the time the *shape* of the naive
kernel already tells you where the compiler will fail: mutual recursion that can't
tail-flatten and falls back to per-call event dispatch; a fold that rebuilds a
structure each step; a value threaded by-copy that should be by-reference. Read the
`.k`, reason about what the optimal binary *should* be, and form the hypothesis
before you open a single line of generated Zig. You can often see it directly.

**Move 2 — Backport from the emitted Zig.** When Move 1 isn't enough — you need the
*exact* fast codegen — open `output_emitted.zig` for the slow kernel, hand-write the
fast Zig, **measure that it is actually faster** (ReleaseFast, same protocol), and
only then teach the emitter to emit that form **1:1**. The `.k` never changes; the
compiler catches up. (This session's `emitSelfTailReentry` snapshot fix was exactly
this: read the bad `k=k-1; acc=…k`, wrote the staged form, backported it. So was
"recursion that was a loop.") Measure-first is non-negotiable — you backport a
*proven* win, never a guess.

**Move 3 — Introduce a high-performance primitive.** When even perfectly-emitted Zig
of the naive code loses — because the win requires a data representation or algorithm
the compiler cannot infer — introduce a library primitive that carries the
optimization, and keep the *caller* naive. `std/field:strike` absorbs what
`primesieve.cpp` spends 348 lines of stepMask/SIMD on; the residue tables are a
one-line comprehension baked to a `const`; the user's sieve stays eight naive lines
and lands at 95% of hand-tuned NEON C++ (see the korulang.org blogs "The Wheel Was
the Wrong Optimum" / "A 35-Line Prime Sieve Now Beats Hand-Tuned Rust"). `kernel`
(the pairwise/self/reduction vocabulary) is the same idea. A primitive may itself
use Move 2 internally (the compiler generates the strided marker).

**The discriminator (Move 2 vs Move 3):** Move 2 when the fast Zig *exists* and the
emitter just isn't producing it — the naive code already maps to an optimal binary,
the compiler is the gap. Move 3 when even optimal codegen of *that* code can't win,
because the win needs a different representation — then a primitive absorbs it while
the caller stays naive.

## The measurement discipline (highest-stakes — these numbers leave the room)

- **Verify ReleaseFast FIRST, before trusting any number.** The emitted binary must
  be ReleaseFast, not Debug/ReleaseSafe/ReleaseSmall (a prior silent trap). Confirm
  empirically (A/B a kernel against an explicit `-OReleaseFast` rebuild) — a
  debug-vs-release board is meaningless.
- **Same protocol, apples-to-apples.** Time under the reference suite's own protocol
  (for the Osprey kernels: `hyperfine -N --warmup 3 --min-runs 10`, `cc -O2` /
  `rustc -C opt-level=3` / `ghc -O2`). Faithful-to-faithful only.
- **Oracle-gate before timing.** A binary whose output misses the oracle is excluded
  — a wrong answer is not a result. (Correctness is `run.sh`; perf is `bench.sh`.)
- **Never time under CPU contention** (no parallel build/sweep running).
- **No "beats/matches X" claim leaves the room** unless SHOWN under the target's
  exact rules on the same machine. Missing toolchains are reported ABSENT, never
  faked or estimated. State the machine. Sandbag; underclaim.

## Verification rigor (a perf change is a compiler change)

Re-measure after the fix; pin a **perf guard** (and a correctness guard if behavior
was near the change). Prove no regression the same way a correctness fix is proven —
solo re-runs of anything suspicious, **pristine isolation** (revert your change,
rebuild, confirm the delta is yours), never a raw snapshot diff across commits.
Green is a *side effect* of the compiler getting more capable — toolchain-first.

## Tooling (this repo's machinery)

- `koru-benchmarks/run.sh` — correctness gate (build through `koruc`, check oracle).
- `koru-benchmarks/bench.sh` — perf board (Koru vs installed reference languages,
  Osprey's protocol, ReleaseFast, oracle-gated).
- `challenges/004_compute_kernel_gap_mining.md` — the gap-mining loop: commission
  contestants under the hard stance to port kernels and surface gaps; drain the
  confirmed ones into pins and toolchain fixes. This skill is the discipline those
  runs follow.
