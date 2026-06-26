# `std/field` (codename `std/castles`) — Vision

> **STATUS: ASPIRATIONAL VISION. NOT A SPEC. NOT ESTABLISHED DESIGN.**
> Per koru/CLAUDE.md, prose drifts and the *tests* are ground truth. Nothing in
> the 🏗️ sections below exists. This file is a direction to build *toward*, not
> a description of what is. When any 🏗️ item lands, it lands as a green
> regression test first — and at that point this prose is the thing that's now
> potentially stale, not the test.

**Marking legend (the thing I forgot last time):**
- ✅ **GROUNDED** — exists in the codebase/corpus today, cited.
- ⚖️ **DOCTRINE** — an already-ruled Koru principle this rests on.
- 🏗️ **CASTLE** — does *not* exist. Speculation. The dream.
- ❓ **HYPOTHESIS** — a specific claim we have *not* verified and must measure.

---

## The one-sentence thesis

🏗️ A dense-buffer compute construct is not a data structure — it's a **declaration
of a computation's *structure*, and structure is backend-agnostic.** Carry the
optimization truth (density · single-owner/no-alias · provable bounds · access
pattern · reduction shape) in the source, and the compiler can lower it
*optimally* to CPU SIMD, GPU, or a hand-scheduled asm micro-kernel — from one
source.

## Why this isn't pure fantasy — the grounded foundation

- ✅ **The island mechanism already exists.** `~[comptime|transform|claims_descendants]`
  (`koru_std/kernel.kz:80`) lets a transform claim its whole subtree, validate it
  against a restricted vocabulary (`kernel.kz:195–271` rejects anything that isn't
  `pairwise`/`self`), collect the ops (`KernelPlan`, `kernel.kz:277+`), and emit
  fused monomorphized Zig.
- ✅ **It already matches hand-specialized C.** The n-body kernel lands within ~1%
  of hand-scalarized C and beats plain C/Zig/Rust by 12–15% (MEASURED — blog:
  *Idiomatic Koru Kernels Match Hand-Specialized C*).
- ✅ **"Restrict the subset → optimality becomes decidable" is a proven Koru move.**
  Regex compiles to a one-pass DFA *because* it refuses backreferences/captures
  under quantifiers — the regular subset is exactly the optimal+safe subset
  (MEASURED: 2× Rust, ReDoS unrepresentable — blog: *Your Regex Is a Branch*).
- ✅ **No-alias is already free.** Phantom single-owner handles (`<grid!>`/`<grid>`/`<!grid>`,
  `koru_std/grid.kz`) are the `restrict`-equivalent, carried in the type.
- ✅ **The codegen engine exists.** `[transform]` monomorphization (regex, `list:new`).
- ✅ **A dense-grid stencil customer already exists in the corpus**, hand-rolled:
  AoC day18 Conway's Game of Life (`810_181`) as a fixed `[8][8]i64` capture array.
- ✅ **A GPU foothold file exists**: `koru_std/gpu.kz`. (Contents UNEXAMINED — I've
  seen one line. Listed as a foothold, *not* a claim it does any of the below.)
- ⚖️ **No silent performance degradation** (RULED 2026-06-17): prove the optimal
  strategy or error; never a silent slow fallback. This is the law the castle
  must obey across every backend.

## The construct 🏗️

🏗️ A `claims_descendants` transform — codename `std/castles`, likely `std/field` —
that owns a runtime-sized, dense, single-owner buffer and exposes a *tiny*
vocabulary: `sweep` (owned bounded iteration), `strike` (strided in-place write),
`neighbor` (stencil read), `reduce` (count/sum/min). It validates its subtree to
that vocabulary and monomorphizes to bit-packed, bounds-check-free, no-alias code.

🏗️ It is the **`kernel` family generalized over data *shape*.** Existing `kernel` =
fixed small set (`pairwise`/`self`, scalarized). New = dense runtime array/grid
(`sweep`/`strike`/`neighbor`, bit-packed/cache-blocked/vectorized). Same spine,
different declared shape. There is **no `std/sieve`** — a sieve is a ~20-line
program written with the construct, exactly as nbody is.

## The architecture that keeps the castle reachable 🏗️

🏗️ The island lowers **not to Zig directly, but to a small portable compute-IR**
(`shape · access · reduce · ownership`). Each backend is a lowering of *that IR*.
Adding a target = a new lowering, never a change to user code. (This is the regex
"the automaton is the portable artifact" move, generalized from strings to arrays.)

```
  field island ──► compute-IR (shape/access/reduce/no-alias)
                        │
      ┌─────────────────┼─────────────────┐
   CPU              GPU                 ASM
   ✅ path:         🏗️ sweep=launch,    🏗️ superoptimized
   bit-packed,      cell=thread,        micro-kernels for
   cache-blocked,   stencil=shared-     the regular cases
   NEON/AVX         mem tile            (machine-searched)
   (Zig→LLVM)
```

### CPU — ✅ the path is real
Lowers to Zig → LLVM auto-vectorizes (NEON/AVX), as kernel already does. Bit-packing
+ owned bounds (no checks) + no-alias are all expressible today in principle.

### GPU — 🏗️ but structurally cheap
🏗️ The constraint that makes the CPU path optimal is the constraint that makes the
GPU path *safe*: a bounded, data-parallel, no-alias sweep over a dense buffer is
the textbook GPU kernel. Phantom single-owner = no data races; bounded sweep = no
divergence; stencil = a tile-able pattern. `--target=metal/spirv` becomes another
IR lowering; the no-alias proof paid for on CPU *is* the parallelism-safety proof
on GPU. Foothold: ✅ `koru_std/gpu.kz` exists (unexamined).

### ASM "limited but ~optimal DSL" — 🏗️ the most tractable castle
🏗️ Over a 6-op ISA (`sweep/strike/neighbor/reduce/...`) you can **superoptimize**:
machine-search the optimal instruction sequence for "strided bit-fill, 64-bit lane,
AVX-512" *once*, cache it, and the island stitches the optimal micro-kernels. A
peephole optimizer over six ops is tractable; an *optimal* one is findable.

## The crazy rungs 🏗️

- 🏗️ **Auto-tiling / polyhedral scheduling**: closed world + declared access →
  cache-blocking, loop tiling, even **mod-30030 wheel-residue specialization**
  *derived* from structure instead of hand-coded. Auto-pick bit-width.
- 🏗️ **One source, three optimal binaries**: write Life / a sieve / a DP table once
  → bit-packed AVX/NEON CPU binary + Metal/CUDA kernel + superoptimized asm kernel.
- ⚖️→🏗️ **Honest across backends**: extend no-silent-degradation so every retarget
  must *prove* it hit the optimal strategy for that target **or error**. Never a
  silently-slow GPU kernel. Three outcomes per backend: prove-optimal / explicit-cost
  / compile-error.

## The open measurement we owe ourselves ❓

✅ **RESOLVED by measurement.** The ~0.6 s of unexplained system time was the **8 MB
i64 buffer** (page-faulting/touching 8 MB every pass). Switching to the 125 KB bit
buffer dropped system time 0.55 s → 0.056 s (10×). It tracked buffer *size*, not the
allocator (safety flag and allocator-wrapper swaps both changed nothing — falsified).

✅ **Bit-packing is size-dependent (measured, pure C, no Koru confound):**
| N | C i64 | C bit | winner |
|---|---|---|---|
| 1,000,000 | 1.18 s | 3.82 s | **i64 by 3.23×** (i64 buffer 8 MB still cache-resident; bit pays RMW for nothing) |
| 10,000,000 | 4.41 s | 4.00 s | **bit by 1.10×** (i64 buffer 80 MB falls out of cache; bit 1.25 MB stays) |

Consequences for the construct:
- ⚖️ Bit-packing must be a **proven-beneficial** choice, not a default — at small N over
  big-cache hardware it's a *pessimization*. The SHAPE gate should pick layout from
  N × element-domain × cache, or error/ask — never silently bit-pack.
- 🏗️ At the drag-race fixed N=1 M, bit-packing pays **only with the wheel** (mod-30030
  keeps ~19% of candidates → shrinks the effective buffer *and* the work). So rung-3
  (wheel index-transform) is load-bearing for the headline benchmark, not polish.

✅ Compute (user) time of the naive i64 Koru sieve is only ~1.25× C — codegen is close.

✅ **LIFECYCLE OWNERSHIP is a measured win (the vision's core claim, proven).** Allocate
the i64 buffer *once* and `clear` it each pass instead of new/free per pass:
| Koru i64 sieve | total | compute | system | vs c-naive |
|---|---|---|---|---|
| fresh alloc/pass | 2.09 s | 1.47 s | 0.58 s | 1.75× |
| **reuse (alloc once)** | **1.39 s** | 1.36 s | **0.022 s** | **1.16×** |
The construct owning the buffer lifecycle erased the per-pass alloc/fault tax
(system 0.58 → 0.022 s, matching C) and closed the gap 1.75× → 1.16×. The residual
1.16× is pure compute codegen. ⇒ "own the lifecycle, present fresh-per-pass
semantics, physically reuse" is a real load-bearing job for the construct, not just
a nice-to-have.

❌ FALSIFIED (B): "fusing the per-cell marking loop will speed it up." Fusing the
strided strike into one Zig op gained ~1% — LLVM already inlined the per-cell `set`.
The bit version's deficit at 1M is layout (RMW vs cache-resident store), not loop
structure. Also measured: ✅ Koru's bit-sieve *beats* `-O2` C's bit-sieve by ~18%.

## First stone (build order) — grounded

1. ✅/🏗️ **Rung 1 — CPU dense bitset**: `sweep`/`strike`/`test`/`count`, generated
   bit-packing, owned lifecycle, proven bounds. Built **as a lowering of the
   compute-IR, not as direct Zig**, so GPU/asm are backends-to-add, not a teardown.
   Prove it against the sieve benchmark (target: match c-naive; settle the ❓ first).
2. 🏗️ **Rung 2 — sieve/stencil vocabulary**: `each-prime` / `neighbor` so Life and
   the sieve are idiomatic with no hand-written index math. (Day18 is the test.)
3. 🏗️ **Rung 3 — index-transform modifiers**: odds-only / wheel, the champion's move.
4. 🏗️ **Rung 4+** — GPU lowering, then the superoptimized asm micro-kernels.

## The compute-IR shape 🏗️ (the keystone)

🏗️ Everything below is castle — the IR does not exist. But it rests on two
structural moves, and ✅ the existing `kernel` already *implicitly* computes a
CPU-only version of most of it (its `pairwise` is an access pattern, its `{...}`
is a body, `step` is the schedule, the fixed Body is the shape, aliasing is
ownership). The dense-kernel makes that IR **explicit, multi-backend, and
schedule-aware.**

### Structural move 1: separate WHAT-CELLS from WHAT-ARITHMETIC
🏗️ Split every op into **ACCESS** (which cells it reads/writes — must be statically
characterizable) and **BODY** (the pure arithmetic — an expression DAG). Access
drives schedule/memory/parallelism; body drives the ALU work (SIMD lanes, GPU
threads, asm). Same separation kernel does implicitly; made explicit it's what
lets one body vectorize on CPU and run as a thread on GPU unchanged.

### Structural move 2: the field we were missing — DEPENDENCY
🏗️ The original four (shape/access/reduce/ownership) glossed the thing that makes
*parallel* backends **correct, not just fast**: the dependency order between cell
updates. Three canonical classes:
- **Independent** — new value depends only on the *previous* pass (Life, double-buffered) → embarrassingly parallel.
- **Idempotent/monotone** — order-free even in-place (sieve `strike` writing 1) → parallel-safe in place, no atomics.
- **Ordered/wavefront** — depends on cells written *this* pass (DP tables) → needs a legal schedule (diagonal/wavefront).

Without this field, a GPU lowering is a guess. With it, the scheduler picks a legal
optimal schedule **or errors** (no-silent-degradation).

### The five fields, and each field's optimize-or-ERROR gate
| Field | Carries | Gate (else ⚖️ error / explicit-cost) |
|---|---|---|
| **SHAPE** | rank, runtime sizes, element domain + **minimal bit-width**, optional index-transform (odds/wheel) | bit-width not statically bounded → can't pack → error |
| **ACCESS** | per-op read/write **sets** (AP/affine/fixed-stencil), not arbitrary code | set not statically characterizable → error or marked atomics |
| **BODY** | pure expression DAG over cell + neighbors | side-effecting/impure → rejected |
| **DEPENDENCY** | independent / idempotent / ordered | no legal schedule provable for target → error |
| **REDUCE** | a monoid (op + identity); recognizes 1-bit `(+,0)` as **popcount** | op not associative → can't tree-reduce on GPU → error/explicit |
| **OWNERSHIP** | ✅ phantom single-owner / borrowed / consumed | alias not provable → error (existing phantom discipline) |

The union of gates passing for target T = "this island lowers *optimally* to T."
Any gate failing = compile error, not a slow fallback. **That is no-silent-degradation
made per-backend and structural.**

### Three workloads through the IR (showing it generalizes + the gates firing)
| | SHAPE | ACCESS | DEPENDENCY | REDUCE | GPU verdict |
|---|---|---|---|---|---|
| **Sieve** | 1D, 1-bit | `strike(p*p, +p)` = AP write | idempotent | `(+,0)`→popcount | ✅ each `p` a thread, no atomics |
| **Life** | 2D, 1-bit, double-buf | `neighbor(8)` read, pointwise write | independent | optional count | ✅ cell=thread, stencil=shared-mem tile |
| **Histogram** | 1D ints | `scatter(f(x))` = data-dependent write | conflicting | `(+,0)` | ⚠️ needs atomics/privatization — **marked explicit-cost, never silent** |

The histogram row is the point: the IR makes the dangerous case *loud*. Scatter's
write-set isn't a static AP, so the gate fires and forces an explicit decision
(atomics, or privatized partials) instead of a silently-serial GPU kernel.

## Wheel ladder — MEASURED + the comptime-table summit route

✅ Hand-rolled wheel climb on `std/field` (1000 passes @ N=1M, Apple Silicon):
| rung | time | passes/sec | note |
|---|---|---|---|
| plain bit-field | 3.29 s | ~304 | bit RMW, no wheel |
| odds-only | 1.16 s | ~860 | beats naive C i64 (~840) |
| **mod-6 wheel** | **0.52 s** | **~1,910** | 2.28× past naive C; ~77% of the champion |
| 🏆 champion `5760of30030` | — | ~2,490 | mod-30030 wheel (wheeled C/C++) |
Correctness gated on the **raw** coprime count (mod-6 → 78,496 = π(10⁶)−2, hand-verified),
not a coincidence. Each wheel rung ~doubles throughput.

✅ **mod-6 is the hand-rolling ceiling.** One prime's marking is already a monster inline
expression (two residues). mod-30 = 8 residues, mod-30030 = 5,760 — infeasible by hand;
it's the table `primesieve.cpp` ships.

🏗️ **The summit route = comptime-baked wheel tables (rung-3 index-transform).** This is the
regex move exactly: ✅ regex is a sub-language read by a `[comptime|transform]` and baked to
native DFA tables (NFA→DFA at comptime is harder work than a wheel). From a single constant
`W`, comptime-derive: coprime residues, the **gap table** (the cyclic residue-gap sequence
primesieve hand-writes), encode/decode, and a *table-driven mark walk* (one loop, not k
strikes). The grotesque inline math dissolves into `wheel(30030)`.

🏗️ Surface (proposed): a comptime index-transform MODIFIER on the field island, not a siloed
DSL — `std/field:over(2..N) wheel(2*3*5*7*11*13)` — so it composes with for/if like every
transform (the bolted-on-macro problem the kernel/Lisp post named). Island owns buffer+sweep;
wheel-transform owns addressing. "A wheel is a regex for the number line; it's known at
compile time, so compile it."

## Comptime boundary — MEASURED (shapes how the table generator must be built)

✅ **Pure-Koru comptime *computation* of a data table is blocked today.** `for`, `if`, and
`capture` are themselves comptime *transforms*, and they don't nest inside a `[comptime]`
evaluation — a `[comptime]` event implemented by a Koru capture-fold fails at the
`! as ... for ...` line (KORU010 "stray continuation"). So the very vocabulary you'd use to
*compute* the wheel (iterate, accumulate, branch) is unavailable for comptime data-generation.

✅ What DOES work at comptime: `[comptime]` events whose bodies are `~proc |zig`, and
comptime *flows* that orchestrate them with `|>` / array literals / `=>` (030_016, 210_030).
The metacircular compiler (`optimizer.kz` is `~[comptime]`) is the proof comptime Koru runs.

⇒ Two honest routes for the wheel-table generator:
- **NOW (proven): a transform-with-Zig-computation**, exactly like regex bakes DFAs — the
  transform's `~proc |zig` computes the gap table at comptime and emits it as a `const`
  array. Real, shippable; the computation is Zig, not Koru.
- **FUTURE (pure Koru all the way down):** either make comptime transforms *nest* inside
  comptime evaluation (the limitation Lars named), or use non-transform control primitives
  that may comptime-evaluate — `#loop` (label recursion) is the one candidate NOT yet ruled
  out (`when` turned out to be tap-gating, not an arithmetic conditional). UNTESTED.

## Architecture: why pure-Koru comptime computation is hard (and what's sanctioned)

✅ **INSIGHT (Lars):** Koru's transforms are **pipeline passes**, not a re-entrant comptime
interpreter. A transform rewrites the AST *during* a pass; it cannot recursively re-run the
whole comptime pipeline inside itself. So comptime transforms (`for`/`if`/`capture`) **cannot
nest fractally.** Jai (Blow) gets fractal comptime via a comptime *VM* that evaluates code to
any depth; Koru has rewriting passes, not a VM. ⇒ pure-Koru comptime *computation*
(iterate/filter/accumulate to build a table) essentially requires a **comptime Koru evaluator**
— the aspirational-interpreter direction ([[project_interpreter_aspirational]]), not a patch.
The "flex" and the interpreter rewrite are the same project.

⚖️ **SANCTIONED:** Zig is a legal compile-time language for Koru. Computing the wheel table in
a transform's `~proc |zig` at comptime (the regex→DFA pattern) is **NOT a shortcut** — it's a
legitimate path, available NOW. The **banned** shortcut is faking it with **Liquid** (a parallel
string-templating DSL) and calling it "Koru computing the table." Pure-Koru comptime computation
is the aspirational **FLEX**, not a correctness requirement.

🏗️ A **`std/table` (also list) comprehension** is acceptable — less elegant than pure-Koru
comptime, but a fine surface. Its substance must be real (a Zig-comptime transform now, or the
flex: a comptime Koru evaluator), **never a Liquid fake.**

**Encoded as failing aspiration tests** (MUST_RUN, currently RED; green when the comptime Koru
evaluator lands): `tests/regression/300_ADVANCED_FEATURES/310_COMPTIME/310_09x_aspire_*`. The
learnings live as red dashboard items, not lost prose.

## The name

`std/castles` is the working codename and it's perfect. Sober candidates: `std/field`
(a field of cells you sweep — current favorite), `std/dense`. Eagle-eye: the honest
name is about the *island that lowers optimally anywhere*, not the buffer — the
buffer is incidental, the retargetable closed-world compute is the invention.
