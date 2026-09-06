# Store Layout Arms — product, view, union

Three declared layouts for one logical workload: sweep every entity and sum the
shared `str` leaf; then the player-narrowed subset, guarded. Koru-only, one
binary, JSON lines out (`elapsed_ns` over the whole timed run, `sink` as the
anti-DCE checksum). The sinks are the oracle: the unguarded arms must sum the
same total, the guarded arms the same subset — divergence means a wrong layout,
not a slow one.

Runs: `./run.sh` (builds with `--release=fast`; `koruc build` defaults to
Debug, which inflates the per-row call overhead and flattens the differences).

## The arms

| arm | spelling | emitted shape |
|---|---|---|
| `separate` | two lone stores, two queries | two loops, one per store |
| `view` | `std/store:view(Entities)` over the same stores, one query | two loops, same body handler, per-loop constant kind |
| `union` | ONE store, `kind` column, all leaves folded | one loop over one extent |
| `view_player` | view query `when e is Player` | two loops; the enemy loop's guard folds to a constant `false` and LLVM eliminates it |
| `union_player` | union query `when e.kind == 1` | one loop, real `kind` column load + data-dependent branch per row |

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
| union | 9.2 | 0.99× |
| view_player | 5.6 | 0.60× |
| union_player | 26.4 | 2.84× |

## What the numbers say

- **The view is the member sweeps.** Unguarded, `view` and `separate` are the
  same to the noise — the polymorphism is free, exactly what the emitted shape
  (two loops, same handler) promises. The union's single extent buys nothing on
  this workload: the sum is cache-resident and str-only, so touching one array
  instead of two does not show.
- **The guard is where the layout decision lives.** Narrowing to players costs
  60% of the full sweep in the view (only the player loop does real work; the
  enemy loop's constant guard is eliminated). The hand-declared union pays 4.7×
  MORE than the view for the same narrowing: every row loads the real `kind`
  column and takes a data-dependent branch, and the branch defeats
  vectorization of the `str` sum. This is the post's claim made measurable —
  "the kind vocabulary is never stored, the `is` guard resolves to a constant
  per member loop, no tag column, no discrimination cost."
- **The union is not refuted, it is unmeasured.** A folded extent wins when the
  shared leaf dominates wide rows and many kinds share it; this benchmark's
  str-only sum cannot show that. The hand-declared union arm is also the
  aspirational surface: `690_296` pins the pooled `std/store:kind` + `set` —
  when it lands, the union arm becomes that spelling and this file gets a
  second measurement.

## The defect this benchmark found

The first build failed: a view query whose body WRITES to another store
(`stored { acc.sink: acc.sink + e.str }`) emitted the shared-leaf read against
the view name — `__koru_store_Entities.str[...]`, a store that does not exist —
because the write path took the `.live` column-read lowering instead of
threading the projection. Fixed in `koru_std/store.kz` (view sweeps thread
`.live` reads as projected inputs; each member loop binds its own column),
pinned by `690_297_view_sweep_write_body_reads_leaf`.
