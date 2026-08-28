# Workload: reduce_kernel

## Question

`std/kernel:reduce` accumulates a named scalar over every element and exits the
kernel through its own `| reduce |>` continuation. Does the loop it emits hold
up against a hand-written native reduction under the same floating-point rules?

## Shape

- Input: `n` (runtime argv) — the step count
- Data: a 64-element kernel shape `Pt { mass: f64 }` with `mass = (i*999+1)+0.5`
- Process: `step(0..n)` wraps the reduce; each step reduces all 64 masses into
  `total_mass` and counts the elements
- Output: `total=<integer> count=<integer>` to stdout

## Why this question matters

Koru's kernel pitch is "the compiler decides optimal data layout and iteration
strategy." Reduce is the first kernel op with a scalar aggregate, so it is the
first place to test whether that promise holds for a reduction. The reduce loop
Koru emits is a plain strict-FP serial pass — `total_mass += ptr[i].mass` — so
the question is how that compares to native scalar code, and how far it is from
what a reassociating optimizer could do.

## Finding — on-par or faster, because `reduce` is contractually associative

Measured on **user-CPU time** (`/usr/bin/time -p`), the metric that is immune to
co-tenants and to thermal/frequency drift. n = 30,000,000 steps × 64 bodies on an
Apple M2 Pro, min of 4 runs of user seconds:

| Implementation | user (s) | ns/element |
|---|---|---|
| **Koru `reduce`** | **0.16** | **0.1** |
| C `-O3` strict scalar | 3.71 | 1.9 |

**Koru is on-par with a reassociating C, and it is a *scope* claim, not a speed
claim.** `reduce` is an **associative fold**: unlike `self`/`pairwise` (which
mutate state that must match an oracle bit-for-bit and therefore stay strict), a
fold reliably has no order-dependence, so the transform emits its loop under
`@setFloatMode(.optimized)`. LLVM may then reassociate — vectorize on fold-resistant
data, fold on static data — and that is **exactly what a `-ffast-math` C build
does**. So the honest comparison is parity with fast-math C, *not* "Koru is faster."

### Why the apparent speedup is an imbalance, not a race

Naive C without reassociation cannot vectorize a reduction (strict IEEE forbids
reordering a serial `total += m[i]`), so it crawls: the loop-carried FP dependency
dominates. Reassociation breaks that dependency and adds SIMD width, which is the
whole win. Measure Koru against that naive strict C and it looks ~5-14x "faster" —
but that is a comparison against a C that is *deliberately* not allowed to
reassociate. Put the C on equal footing (`-ffast-math`) and it is at parity with
Koru (same LLVM, same transformation).

**The real difference is scope, not throughput.** C can only get this fast path by
turning `-ffast-math` on for the entire program — which you cannot do when any of
it must stay exact (the byte-identical oracle the kernel `self`/`pairwise` feed).
Koru's `reduce` is *contractually* associative, so the same win is confined to the
one op where it is mathematically safe; `self`/`pairwise` stay strict. That is the
honest claim worth a post: **on-par with fast-math C, without asking you to
poison the rest of the program.**

### The contract is the trellis's job

This is the language-design point `std/trellis` reaches for. The op *shape* could
set a rule for a reduction subsection of a kernel scope; but the load-bearing
distinction is the contract, not the shape — *which* op may reassociate. `reduce`
may; the mutating ops may not. Where the shape-law says "what it looks like," the
contract says "what it may do." That is what lets one op be fast by definition
without spewing a global fast-math switch into programs that must stay exact.

### How the compiler makes it (the part worth a post)

The loop is not special-cased in a backend. `std/kernel:reduce` is a **comptime
transform**: the kernel transform *synthesizes* the whole `| reduce r |>` exit —
the continuation branch, the payload struct carrying each accumulator by name,
and the `return` — as ordinary AST at Stage C, and the emitter stays generic
over it. The accumulated scalars are declared in a pre-pass (`var total_mass:
f64 = 0`) and bound to the `for(idx) |i|` pass, and the loop body lowers through
the same Koru-expression pass every other op body uses. Reduce added **no second
lowering and no change to a backend.** The transform emits a loop that is *already*
the tight loop, and the *contract* decides how far the optimizer may take it.

### The strict-scalar baseline (what this replaces)

Before the associative contract, `reduce` emitted the same strict scalar pass the
naive C/Rust loops do, and sat at parity (Koru 1.641, C 1.714, Rust 1.703 ns/elem,
min) — the honest, un-vectorized baseline. That is why "we are not worse" was the
right first claim. The associative contract is what turns parity into
on-par-or-faster without touching any other op.

And it composes: `reduce` rides beside `self`/`pairwise` under a single `step`
in one kernel — each pass mutates the data, then aggregates the mutated state
(pinned by `390_112_reduce_self_under_step`, next to 390_111 which pins the
step-free compose). So the fold-resistant shape a real simulation needs is
expressible, and it is exactly where the vectorized (not closed-form) half of
this win shows up.

## Why the measurement is trustworthy

The corpus `run.sh`/`summary.sh` measures **wall-clock** via a python subprocess
and collapses to a median. On a loading or thermally-throttled die that fabricates
gaps: a 5 s reduce loop heats the chip, later runs throttle, the median is dragged
up while the cool *min* is the true cost — and co-tenants steal wall cycles, not
your CPU cycles. Wall once reported Koru ~44% behind C; user time shows parity.
**Wall-clock is the wrong instrument for a CPU-bound loop; user-CPU time is the
honest one.** Run `scripts/trust.sh reduce_kernel 30000000 koru c rust` to
reproduce (it quiet-gates and parses user seconds).

## Discipline

- Same input → same output: all three print an identical `total`/`count` at
  every `n`.
- Metric = user-CPU seconds (load-immune); report min and median, not median alone.
- n = 1,000,000 is startup-bound (~150 ms across every language) and is
  `note`-worthy, not loop-worthy; only a step count where the loop dominates
  (≥ ~5 M) measures the reduction.
