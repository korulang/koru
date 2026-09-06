# Store Layout Arms — product, view

Two declared layouts for one logical workload: sweep every entity and sum the
shared `str` leaf; then the player-narrowed subset, guarded. Koru-only, one
binary, JSON lines out (`elapsed_ns` over the whole timed run, `sink` as the
anti-DCE checksum). The sinks are the oracle: `separate` and `view` must sum
the same total, `view_player` the same player subset — divergence means a
wrong layout, not a slow one.

Runs: `./run.sh` (builds with `--release=fast`; `koruc build` defaults to
Debug, which inflates per-row call overhead and flattens the differences).

## The arms

| arm | spelling | emitted shape |
|---|---|---|
| `separate` | two lone stores, two queries | two loops, one per store |
| `view` | `std/store:view(Entities)` over the same stores, one query | two loops, same body handler, per-loop constant kind |
| `view_player` | view query `when e is Player` | two loops; the enemy loop's guard folds to a constant `false` and LLVM eliminates it |

Population: 60 000 players (`str`, `mana`) + 40 000 enemies (`str`, `armor`);
`str` is the shared leaf. 1000 frames of the sweep per arm.

## Results

Apple M2 Pro, arm64, ReleaseFast. `elapsed_ns` per 1000 frames of 100 000 rows;
median of four runs. Sinks agreed exactly across all arms on every run
(49 950 000 000 unguarded, 29 970 000 000 guarded).

| arm | ms | vs separate |
|---|---:|---:|
| separate | 9.3 | 1.00× |
| view | 9.2 | 0.99× |
| view_player | 5.6 | 0.60× |

## What the numbers say

- **The view is the member sweeps.** Unguarded, `view` and `separate` are the
  same to the noise — the polymorphism is free, exactly what the emitted shape
  (two loops, same handler) promises. This is the post's claim made measurable:
  the kind never materializes as data, and the unguarded view query is not a
  slower way to sweep two stores.
- **The guard is cheaper than the sweep.** Narrowing to players costs LESS than
  the full sweep (5.6 vs 9.3 ms): the view's `is` guard resolves to a constant
  per member loop, so the enemy loop's guard is a constant `false` and the
  whole loop is eliminated. 60 000 real row-processings beat 100 000. The
  guard is a proof the loop already satisfies — the emitted tag check is its
  receipt, and the receipt costs nothing.

## Postponed surfaces — deliberately not measured here

The pool (`std/store:set` over kinds) and the exclusive pool
(`std/store:union`) are not in this benchmark:

- **`set`** — `690_296` pins the target surface as ASPIRATIONAL (red by design
  until `std/store:kind` + the pooled set land). The set's kind layer is an
  abstract shape — the set needs abstract/virtual machinery to dispatch
  inserts and queries over kind identities, not just a fold. Noted in
  `690_296`'s header.
- **`union`** — postponed entirely; "an exercise in more than just if over a
  collection." Its runtime content (exclusive active kind, max-member extent,
  clear-on-switch) is comptime layout + program state; its reads are views
  already.

A hand-declared flat pool with a per-row kind tag (a hand-written version of
the set's flat-pool end) was tried and dropped. It measured ≈3× slower than
the view on these read-mostly sweeps — but that number belongs to ONE end of
the set's open flat-vs-segmented question (`DESIGN.md`: segmentation drops
the per-row tag but splits the shared extent), not to a landed surface. When
the set lands, it gets its own arm and a real measurement.

## The defect this benchmark found

The first build failed: a view query whose body WRITES to another store
(`stored { acc.sink: acc.sink + e.str }`) emitted the shared-leaf read against
the view name — `__koru_store_Entities.str[...]`, a store that does not exist —
because the write path took the `.live` column-read lowering instead of
threading the projection. Fixed in `koru_std/store.kz` (view sweeps thread
`.live` reads as projected inputs; each member loop binds its own column),
pinned by `690_297_view_sweep_write_body_reads_leaf`.
