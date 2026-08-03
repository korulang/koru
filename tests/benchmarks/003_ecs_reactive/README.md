# ECS Surface Benchmark

This is a small harness for comparing Bevy ECS against a static Zig baseline for
the parts of ECS that matter to Koru's intended execution model. It is
intentionally plain: each binary emits one JSON line per run.

## Scenarios

- `spawn`: spawn entities one at a time.
- `spawn_batch`: batch spawn entities.
- `despawn`: despawn all entities.
- `add_remove`: add and remove a marker component/flag.
- `query_get`: random-access entity/component lookup.
- `dense`: all entities have position and velocity; update all positions.
- `sparse`: 10% active entities; update only active entities.
- `schedule_empty`: run an empty scheduled system/function.
- `fanout`: damage events mutate health, then observer-style work fans out.
- `combat_world`: a deterministic console simulation with enemies, projectiles,
  spatial buckets, movement, collision, damage, death, and fanout bookkeeping.
- `bevy_strength_world`: packed dense archetypes with dynamic bodies,
  particles, orbiters, modular systems, command cleanup, changed-component
  checksum, and math-heavy iteration. This is intended to favor Bevy ECS.
- `archetype_churn_world`: Bevy-only anchor that moves entities between
  archetypes during the workload: `Idle`, `Seeking`, `Attacking`, `Stunned`,
  and `Dead`. It uses `Commands` for component insert/remove, real queries over
  changing marker/component sets, health changes, and a deterministic checksum.
- `boids`: Unity DOTS `BoidSystem.cs`, ported. Four arms — the only scenario with a legion entry. 100_000 flocking boids over a
  32³ spatial grid: quantize, scatter heading and position into cells, resolve
  each occupied cell's nearest target and obstacle, then steer every boid from
  its cell's aggregate. DOTS' own constants, unscaled. This is the first
  scenario in the harness that needs a SPATIAL INDEX.

The Zig baseline is not the final Koru implementation. It is the straight-line
shape Koru should generate for static storage, indexed sparse work, lifecycle
operations on static arrays, and fused reactive fanout.

## The Koru entry

`koru_store/main.k` is a third arm, built from source by `run.sh`. Everything
in it is Koru — the flag parser, the world, the systems and the emitter. There
is no `~proc|zig` in the file; the only host code it reaches is the standard
library.

Eleven of the twelve scenarios are ported. A scenario the entry has not ported
refuses on stderr and emits no line, so an absent row in `results.jsonl` means
"not implemented", never "ran and produced nothing".

### What the port had to change, and why

These are structural, not conveniences. Each one is a property of the store's
design, and the benchmark exists to make them visible rather than to route
around them.

- **Store capacity is a compile-time literal.** The world is SIZED for the
  harness's 100_000 entities rather than allocated per run. `--entities` above
  the declared capacity is refused by `insert`'s `full` arm, not truncated.
- **A cell names a row by handle, never by position.** The baseline's
  `pos_x[0..16]` checksum tail is not spellable, so the checksum is a
  whole-store sum read back OUTSIDE the timed region — a stronger oracle, and
  `std/time:now` is opaque enough that the read cannot be hoisted over it.
  `query_get`, `fanout` and `bevy_strength_world` accumulate their own sink as
  the workload runs, exactly as the baseline does.
- **`sparse` scans.** The baseline walks a 10%-dense index array; Koru has no
  index verb, so the filter is a `when` guard and the sweep still visits every
  row. That is why Koru is the slowest of the three here and the gap is the
  measurement, not a detail to hide.
- **`fanout` cannot pick its victim by index.** The baseline damages
  `health[(frame*131 + i*17) % len]`. Handle-addressing makes that access
  unspellable, so the port keeps the event COUNT (entities/10 per frame) and
  the per-event observer work identical and damages the every-tenth rows
  instead. The three impls' sinks all differ here — bevy_ecs's already differed
  from the baseline's before Koru existed.
- **`spawn_batch` IS `spawn`.** Koru has no batch-insert verb, which is the
  same statement the Zig baseline makes by aliasing the two. bevy_ecs's
  batch path is genuinely faster than its own single spawn.

### combat_world has no Koru entry, and the reason has narrowed

This section used to end: *"A spatial index is the first thing a borrowed ECS
workload asked for that `std/store` has no answer to."* That sentence was true
when it was written and is now half wrong, so here is the correction rather
than a quiet edit.

`std/grid` is the answer to the spatial-index half — a static,
positionally-addressed table declared beside the store, with no handle to
thread and nothing to allocate. `boids` is the proof: it is the same quantize/
scatter/gather that combat_world's collision pass wants, it is ported, and its
checksum agrees with the other two arms bit-for-bit.

What still has no spelling is combat_world's BUCKET: each cell holds a list
that grows to however many enemies land in it, and a grid cell's columns are
fixed at compile time exactly as a store row's are. The alternatives remain a
capacity chosen by guesswork or a different algorithm. The pieces for the real
answer now exist and have not been assembled — a cell holding the HEAD of an
intrusive chain, with each enemy row carrying `next`, which needs no nested
collection and no new verb (`690_245`/`690_246` pin the two reads that make it
walkable). Until someone writes it the row stays missing, and it stays missing
for a smaller reason than before.

So the corrected claim: **a spatial index was the first thing a borrowed ECS
workload asked for that `std/store` had no answer to, and the answer turned out
to be a second table rather than a bigger store.**

### Results

One run of `./run.sh`, same machine, interleaved by scenario. Times in
microseconds; `x bevy` is bevy_ecs divided by koru_store. `=` marks a scenario
whose `sink` is bit-identical across all three arms — eleven of twelve now, so
the multipliers below have equivalence evidence behind them everywhere except
`fanout`, which is documented above as damaging a different victim set.

| scenario | zig_striped | bevy_ecs | koru_store | x bevy | = |
|---|---:|---:|---:|---:|:-:|
| schedule_empty | 28 | 867728 | 0.04 | — | = |
| add_remove | 33 | 10787 | 349 | 31x | = |
| spawn | 242 | 3654 | 465 | 7.9x | = |
| spawn_batch | 236 | 3231 | 499 | 6.5x | = |
| despawn | 228 | 3696 | 1051 | 3.5x | = |
| query_get | 1308 | 38728 | 1696 | 23x | = |
| dense | 2370 | 9755 | 3100 | 3.1x | = |
| sparse | 2065 | 2631 | 4722 | 0.6x | = |
| fanout | 8543 | 25452 | 14260 | 1.8x | ✗ |
| bevy_strength_world | 21076 | 65322 | 16627 | 3.9x | = |
| combat_world | 3560 | 9832 | — | — | — |
| boids | 217432 | 314904 | 98350 | 3.2x | = |

Three of these are worth naming.

**`bevy_strength_world` is the scenario this README says is "intended to favor
Bevy ECS", and Koru is the fastest of the three** — 1.2x faster than the
hand-written striped Zig baseline, measured interleaved over five alternating
pairs (Koru 16.35-16.73 ms, Zig 21.12-21.65 ms). Its checksum,
`309294973115`, is bit-identical across all three implementations, so the three
are provably doing the same arithmetic. Why Koru wins is not established: the
plausible reading is that the baseline reaches its columns through `self.*`, a
pointer to a struct of slices, while Koru's columns are module-level arrays at
statically known addresses with no aliasing question — but that is a
hypothesis, and `probes/ab_codegen.py` is the instrument that would settle it.

**`schedule_empty` is 83 nanoseconds for 100_000 frames** because Koru resolves
the schedule at compile time. There is no per-system dispatch, so the loop
folds; the sink still comes out at 100_000. bevy_ecs pays 971 ms for the same
work and the Zig baseline pays 31 us for 100_000 indirect calls. This number is
only readable at all because `std/time` was moved onto a monotonic nanosecond
clock while writing this entry — on the previous wall clock, which ticks in
whole microseconds on darwin, it reported zero.

**`boids` is the borrowed workload. Naive Koru is at parity with hand-tuned
`-O3` C running the same data layout — and an expert still beats both.**

| arm | boids | what it is |
|---|---:|---|
| zig_steelman | **78.0 ms** | expert Zig, full optimisation ladder |
| C, AoS grid cell | 85.3 ms | hand-tuned, better layout than Koru's |
| C, SoA grid cell | 94.9 ms | hand-tuned, **Koru's own layout** |
| **koru_store** | **100.1 ms** | **naive port** |
| zig_striped | 217 ms | idiomatic hand-written Zig — a WEAK baseline, see below |
| legion | 234 ms | safe indexing, default cost model |
| bevy_ecs | 315 ms | |

Checksum `592303452` in every cell, verified interleaved on one machine.

**The comparison that means something is the middle pair.** Against C carrying
Koru's exact grid layout, the residual is 3.6 ms — 3.7%, and smaller than the 9%
spread C itself moves through across two loop shapes and two clangs (95.3 to
104.0). Koru's emitted code is at parity with `-O3` C. Any single-toolchain C
number is a point sample, not a reference.

**Do not read the 217 ms row as a 2.2x win.** It is a real measurement of
idiomatic hand-written Zig, and it is also a weak baseline: the same algorithm,
written by an expert on the same toolchain and machine, runs at 78 ms. The
defensible claim is the narrow one — **naive Koru performs like competent `-O3`
C, and like Zig that nobody wrote.** Koru is not the fastest thing in this
table; it is the fastest thing nobody had to try to write.

"Hand-tuned C" means static arrays, no bounds checks, per-component ternaries:
every vectoriser precondition cleared by someone who knew it was there.

### Why the ECS arms are slow, and it is three bars not one

A per-element loop vectorises only if it clears all three, and the 2x2x2
ablation says globals are NECESSARY while either body rewrite is SUFFICIENT
once they are present. Neither half does anything alone.

1. **Legality.** A trapping bounds check is an early exit and LLVM refuses
   outright — "Cannot vectorize early exit loop with more than one early exit".
2. **Aliasing.** With heap-allocated columns LLVM will not widen the loop at any
   body shape; the runtime alias checks make it unprofitable outright.
3. **Cost model.** Legal and alias-free is still not enough — the vectoriser
   prices the lane-insert gathers and can decline. With static globals the loop
   sits exactly on the cost edge, and removing either remaining obstacle tips it
   over. rustc declines until forced.

**Koru clears all three without anyone deciding to.** Its trap edge is waived at
the declaration (`[unsafe(bounds)]`), its columns are module-level arrays at
static addresses, and its emitted per-component selects are the shape the cost
model accepts. None of the three is a performance feature; each falls out of the
design for an unrelated reason.

Measured corollary: the Zig baseline reaches 113 ms from TWO source changes —
columns as module-level fixed arrays, and replacing a runtime index into a
`[2]Vec3` alloca inside the hot loop with a scalar select. Globals alone move it
4 ms; the body fix alone on heap slices moves it nothing. **Nothing here is a
ceiling on Zig or Rust** — the finding is what you must know, not what is
reachable.

### The emitted steer loop is at codegen parity with clang

Disassembled, innermost steer loop, per four boids:

| | instrs | NEON | `fsqrt.4s` | `fdiv.4s` | stores |
|---|---:|---:|---:|---:|---:|
| clang 22, C probe | 251 | 182 | 6 | 9 | 6 |
| clang 20, C probe | 247 | 184 | 6 | 9 | 6 |
| koru `boids` | 305 | 221 | 6 | 9 | 15 |
| koru `steer_best` | 259 | 201 | 6 | 9 | 6 |

The divide/sqrt core — which dominates this loop — is **identical** across Koru
and both clangs, at the same width, with no explicit SIMD anywhere in the
emitted Zig (zero `@Vector`/`@splat`/`@reduce`). Steer phase: koru 58.8 ms,
repaired Zig 58.2, forced Rust 63.1. There is no headroom in the arithmetic.

The store count is the one place Koru is behind and it is **not collectible**.
`steer_capture_event.handler` emits 14 vector stores per four boids against
clang's 6, because the steer ends in two chained `stored` blocks — the move,
then the clamp — and two chained blocks are two transactions, so px/py/pz are
written unclamped and then written again.

Nothing in the program watches them (zero `watch`, zero `intercept`), and
subscriptions are compiled into the write path, so the compiler knows the
observer set is empty at comptime and could fuse the two transactions itself.
**Tested by hand and it is 2 ms SLOWER** — `boids_fold`, 99.8 against 97.6 over
seven interleaved rounds, same checksum. Fusing makes the single body fatter and
this workload punishes fat bodies, the same direction the ladder shows. The
scenario is kept as a falsifier so compiler-side transaction fusion is not built
on the strength of a store count. Likely reading, not verified: the extra stores
are capture-slot spills, which would make body size the cause and the store
count a symptom.

### Three claims this README used to make, all retired

**"Our static data model is why we are fast."** Half right, and stated wrongly.
Globals are necessary — but alone they moved the Zig baseline 222.8 -> 218.8 ms,
4 ms. They only pay in conjunction with a body shape the vectoriser will take.

**"The verbosity is the optimisation."** The steering was 12,983 characters of
per-component inlining, which this file first called a defect and then briefly
called the mechanism. Both wrong. `boids_helpers` rewrites it with a `nsafe-c`
subflow helper and capture slots — 3,497 characters, 4x smaller — and runs at
the same speed, still vectorised. What IS load-bearing is the emitted SHAPE:
per-component selects, priced at 1.7x against an integer-mask form inside
already-vectorised code. The short source produces that shape too.

**"It is an LLVM version difference."** Refuted: the same C source vectorises
under clang 20 and clang 22 alike. The surviving open question is narrower and
real — LLVM 22 vectorises this loop from clang and declines it from rustc, so
the frontends hand it different IR for the same source intent.

### The steering ladder, and the cliff that was a costume

Every variant computes identical arithmetic and prints `592303452`, so shape is
the only variable. Medians of interleaved rounds:

| steering shape | before the two fixes | now |
|---|---:|---:|
| `boids` — capture slots, one pass | 243 ms | **100 ms** |
| `boids_helpers` — same, via a subflow helper | — | 100 ms |
| `boids_fused` — columns, one pass | 400 ms | 106 ms |
| `boids_f2` — columns, first two fused | 265 ms | 120 ms |
| `boids_split` — columns, seven passes | 261 ms | 120 ms |
| `boids_f4` — columns, four fused | 279 ms | 143 ms |

This table used to carry a story about a cliff: column-routed intermediates were
flat while the body stayed small, then collapsed, with the fused single-pass
version worst by 1.6x. **The ordering has reshuffled, not merely the
magnitudes** — `boids_fused` went from worst to second fastest, `boids_f4` is
now last.

The reading, stated as the hypothesis it is: the cliff was never about body size
or register pressure. A fat body defeated inlining of the per-field write calls,
which put the trap edge back inside the loop, which blocked vectorisation — the
vectorisation boundary wearing a costume. Both fixes removed it. The residual
100-to-143 spread is an ordinary cost of round-tripping intermediates through
columns. Testable by rebuilding the ladder against the pre-`91c6219b` grid; not
done.

### Where the remaining 22 ms is, ranked

Measured against `zig_steelman` at 78 ms. **These are available to any language,
and C does not have them either** — the 95 ms C cell is 22% off the steelman on
the identical layout.

| | kind | worth | evidence |
|---|---|---:|---|
| AoS grid cell | LAYOUT | ~9.5 ms | 9.67 ms in C (94.92 -> 85.25), 8.95 ms in Zig (scatter 35.6 -> 26.8), 1.66x on scatter in a controlled Rust A/B |
| 16-wide vectors | CODEGEN | ~10 ms | LLVM picks 4; 8 and 32 are worse, 12 is 2.3x worse (bad legalisation) |
| hoist cell invariants | CODEGEN | 4.8 ms | `a/n`, `f32(count)`, target choice are per-CELL but recomputed per BOID; LICM cannot see through a gather |
| skip dead select arm | — | 8.2 ms | needs ownership of the vector grouping; not reachable by an auto-vectorising emitter |
| occupied-range resolve | LAYOUT | 1.4 ms | the sweep scans all 32768 cells; occupied span is ~1000 |
| steering store count | CODEGEN | 1.5 ms | the 15-vs-6 item above; a fix already exists in `steer_capture_best` |

One thing Koru cannot spell is currently an ADVANTAGE: it cannot fuse the hash
pass with the grid scatter, and on its own toolchain the split shape is the
faster one (39.4 ms split against 49.8 fused). Under Homebrew clang 22 the sign
flips. Do not "fix" it.

### The layout item is not a disadvantage — it is an unimplemented ruling

The AoS cell is the largest item, and it is NOT what separates Koru from C: the
C probe carries a struct-of-arrays grid too (`boids.c:25-33`, nine parallel cell
arrays), so it has Koru's exact layout and still lands at 94.9 ms. An earlier
draft of this file got that wrong.

More importantly, **it is the one item on the list that is not a gap.** The
store design already rules it: *"layout is the closure of the queries —
projections become SoA columns, predicates become maintained views."* The grid
does not honour that ruling; it emits nine parallel columns unconditionally,
whatever the program does with them.

Koru is the only arm in the table that could decide this automatically, and for
a structural reason rather than an ambitious one: **every access site is
comptime-visible and no pointer to a column escapes.** Columns are declared, not
allocated; the store transform already walks every reference in the program to
compile subscriptions into the write path; and second-class-ness means layout is
unobservable to the source. A C or Zig programmer must pick by hand and live
with it. Koru has the information to pick per access pattern and currently
throws it away.

This workload is the argument for doing it, because it wants BOTH answers at
once: the scatter touches seven fields of ONE cell at a random index (seven
cache lines where a record needs one — wants AoS), while the resolve sweep reads
one field across ALL cells (wants SoA, and Koru wins that phase today, 1.83 ms
against 2.3). The decision is therefore not a global toggle but a clustering of
co-accessed fields, which is exactly what "the closure of the queries" means and
exactly what the compiler can already see.

### `[unsafe(bounds)]`, and the loud-and-fast path that does not exist

The scenario declares its grid `[unsafe(bounds)]`. That is apples-to-apples
rather than a thumb on the scale: every other arm indexes without bounds checks,
so the checked build had Koru doing strictly more work than the things it is
measured against. Both numbers are on record — the waiver is worth 89 ms, 47%.

Loud-and-fast was tried first and is not available. Clamping the index and
recording the violation in a flag, panicking after the sweep, measured 190 ms —
no better than trapping, because the flag is a memory write inside the loop and
that is a loop-carried dependency of its own. A branch is fine; a `noreturn`
target is not; a memory write is not. The escape hatch is therefore explicit and
named, and refuses both a bare `[unsafe]` and an unknown facet (697_008,
697_009).

### Deviations from the sample, and disclosure

Two deviations, held by all arms and recorded in `koru_store/main.k`: a dense
bounded grid instead of DOTS' sparse hash map (so positions clamp and a clear
pass exists), and CORRECT accumulation — Unity's `MergeCells.ExecuteNext` reads
`cellAlignment[cellIndex] += cellAlignment[cellIndex]`, doubling the accumulator
instead of adding the member, a long-standing bug in the sample.

There is no DOTS arm. Unity is not installed here, so `boids` is a port verified
against DOTS' published source, not a measured head-to-head with DOTS.

`boids` init is OUTSIDE the timed region in every arm, so this row does not
carry the construction-inside-timing asymmetry the older rows disclose.


## Run

```sh
./run.sh
```

To run only the Bevy archetype-migration anchor:

```sh
./run_bevy_anchor.sh
```

To run the matching Flecs anchor:

```sh
./run_flecs_anchor.sh
```

To run the matching Unity DOTS anchor, install/open with Unity 6 and set
`UNITY` if the executable is not in the default location:

```sh
UNITY=/path/to/Unity ./run_unity_dots_anchor.sh
```

The Rust/Bevy benchmark needs Cargo to fetch `bevy_ecs` on first run. The Zig
baseline has no external dependencies.
