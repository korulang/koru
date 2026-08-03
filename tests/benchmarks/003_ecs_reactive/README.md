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
- `boids`: Unity DOTS `BoidSystem.cs`, ported. 100_000 flocking boids over a
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
| boids | 220362 | 314533 | 137792 | 2.3x | = |

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

**`boids` is the borrowed workload, and Koru is 1.60x FASTER than hand-written
striped Zig** — 137 ms against the baseline's 220 ms, and 2.3x faster than
bevy_ecs's 314 ms, with a `592303452` checksum bit-identical across all three
arms in every run and across every variant below. It is a port of Unity DOTS `BoidSystem.cs` with DOTS' own
constants unscaled (CellRadius 8, weights 1/1/2, ObstacleAversionDistance 30,
MoveSpeed 25), so the arithmetic is somebody else's design and not one chosen
here to flatter anything.

**WHERE THE INTERMEDIATES LIVE IS THE WHOLE STORY, and this README got it wrong
twice before getting it right.** The steering holds four intermediate vectors.
In C#, Zig and Rust they sit in registers. In Koru they can sit in a `capture`
block — which is an expression-local binding, and the thing two earlier drafts
of this section asserted the language did not have. It does; it nests under an
effect arm, and a store query arm is one.

Every variant below computes identical arithmetic and produces the identical
checksum, so the shape is the only variable:

| steering shape | before the write-path fix | after |
|---|---:|---:|
| `boids_split` — columns, seven passes | 261 ms | **137 ms** |
| `boids_f4` — columns, first four fused | 279 ms | 142 ms |
| `boids` — capture slots, one pass | 243 ms | 238 ms |
| `boids_fused` — columns, one pass | 400 ms | 260 ms |

THE SECOND COLUMN IS THE STORE'S WRITE-PATH FIX, and it is the whole story.
A multi-field `stored` block used to emit one write call PER FIELD, in order,
each carrying the whole row's payload — which is why a later entry could read an
earlier entry's result (690_126) and why column-routed steering was slow. The
block is ONE write by design, so it is now one call: every rhs is an argument,
arguments evaluate before the call, pre-state falls out, and N-1 calls per block
disappear. Column-routed writes roughly halved.

The correctness bug and the performance bug were the same bug. Nothing in the
benchmark changed between the two columns.

What did NOT move is the capture version, 243 -> 238 ms, which says its cost was
never in the store write — and it is now the SLOWEST of the four, having been
the fastest before. Why a capture slot is dearer than a column is open. So is
the residual fused-vs-split gap (260 vs 137): halving both did not close it, so
whatever makes a fat per-row body fall off a cliff is still unexplained and is
not the write path.

The mechanism behind the cliff is visible in the emitted code: **a multi-field
store write emits one write-path call per FIELD, and every call carries the
whole row's worth of value slots** — all thirteen columns, zeros in the ones it
is not writing. That is free only while the call inlines and the field selector
folds away; a body big enough to defeat that pays for all of them at once. WHY
the fused body crosses the line is NOT established — inlining budget, register
pressure, and lost auto-vectorization are all live candidates, and the ladder is
the instrument that would tell them apart. The variants are Koru-only and are
deliberately not in `run.sh`'s scenario list (the other arms would refuse them
and `set -eu` would abort the run); run them by hand against `koru_store/a.out`.

*The steering is still 12.7k characters of Koru from about 40 lines of C#.* A
`capture` names the intermediates but nothing names a subexpression WITHIN one,
so each shared term is written out once per component and left to LLVM to CSE.
That is the verbosity finding, and unlike the performance claim it survived
contact with the measurements.

Two deviations from the sample are recorded in `koru_store/main.k` and hold for
all three arms: a dense bounded grid instead of DOTS' sparse hash map (so
positions clamp and a clear pass exists), and CORRECT accumulation —
`MergeCells.ExecuteNext` in the Unity sample reads `cellAlignment[cellIndex] +=
cellAlignment[cellIndex]`, doubling the accumulator instead of adding the
member, which is a long-standing bug in the sample.

`boids` also fixes a disclosure problem the older rows have: its init is
OUTSIDE the timed region in all three arms, so it does not carry the
construction-inside-timing asymmetry documented for the rest of the table.

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
