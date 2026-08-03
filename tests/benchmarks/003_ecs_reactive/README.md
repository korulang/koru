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

The Zig baseline is not the final Koru implementation. It is the straight-line
shape Koru should generate for static storage, indexed sparse work, lifecycle
operations on static arrays, and fused reactive fanout.

## The Koru entry

`koru_store/main.k` is a third arm, built from source by `run.sh`. Everything
in it is Koru — the flag parser, the world, the systems and the emitter. There
is no `~proc|zig` in the file; the only host code it reaches is the standard
library.

Ten of the eleven scenarios are ported. A scenario the entry has not ported
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

### combat_world has no Koru entry, and that is the finding

It is the one scenario the store cannot express. Its collision pass rebuilds a
64x64 grid of spatial buckets every frame, each bucket a list that grows to
however many enemies land in that cell. A store's columns are fixed at compile
time, so a per-row list has no spelling; the alternatives are a bucket capacity
chosen by guesswork, or dropping the index and scanning every enemy per
projectile, which is a different algorithm and would measure nothing.

So the honest report is a missing row. **A spatial index is the first thing a
borrowed ECS workload asked for that `std/store` has no answer to.**

### Results

One run of `./run.sh`, same machine, interleaved by scenario. Times in
microseconds; `x bevy` is bevy_ecs divided by koru_store.

| scenario | zig_striped | bevy_ecs | koru_store | x bevy |
|---|---:|---:|---:|---:|
| schedule_empty | 31 | 971417 | 0.08 | — |
| add_remove | 38 | 11731 | 366 | 32x |
| spawn | 341 | 4104 | 534 | 7.7x |
| spawn_batch | 270 | 2897 | 530 | 5.5x |
| despawn | 265 | 3635 | 1132 | 3.2x |
| query_get | 1397 | 39357 | 1627 | 24x |
| dense | 2652 | 9133 | 2763 | 3.3x |
| sparse | 2075 | 17402 | 4462 | 3.9x |
| fanout | 9278 | 25320 | 14929 | 1.7x |
| bevy_strength_world | 21575 | 65908 | 17833 | 3.7x |
| combat_world | 3702 | 6734 | — | — |

Two of these are worth naming.

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
