---
census: std/grid
measured: 2026-10-29
against: koru main 9f8576850 (fleet worktree Cypoe/challenge-022-the-std-surface-census, HEAD)
consumers: in-tree suite + koru_std + tools; /mnt/w/src/koru-libs (65 qualified sites); /mnt/w/src/koru main checkout (older tree, overlapping suite); orisha, DOOM, bend, koru-examples — zero sites
---

# std/grid — the organ that is all transform, designed ahead of its consumers

14 files: `grid.kz` (hub, `~part`-joins 13) + 9 verb parts + 4 machinery parts
(`read`, `readwalk`, `idx`, `cursor` — ~41 KB of lowering, no `~pub tor`).
Every pub tor is `~[comptime|transform]` (or `~[keyword|declaration]` for
`slice`) — like `std/store`, the whole namespace is a program-rewriting
surface; there is no runtime library underneath to census.

## The table

Counts: non-comment `std/grid:<tor>` call-lines across tests/, examples/,
koru_std/, tools/ in-tree (files in parens) + koru-libs occurrences.

| tor | classification | evidence |
|---|---|---|
| `new` | **live** — transform (`keyword`) | ~72 lines / 43 files in-tree + 14 koru-libs; two arg shapes (`size:` / `dimensions: NxM`), `[unsafe(bounds)]` waiver surface (5 sites in benchmarks/003_ecs_reactive) |
| `stored` | **live** — transform (`keyword`) | ~97 lines / 39 files + 48 koru-libs; the write join, mirror of `store:stored` by design |
| `sweep` | **live** — transform (`keyword`, `claims_descendants`) | ~31 lines / 20 files + 3 koru-libs; visit-every-cell, rewrites `c.field` to source-level grid addressing so `stored` can write it |
| `for` | **live** — transform (`claims_descendants`) | ~20 lines / 7 files — **suite-only** (697 cluster + 115_045); grid-owned loop minting trusted cursors `__koru_gi_<g>_L<line>` |
| `walk` | **live** — transform (`claims_descendants`) | ~18 lines / 5 files — **suite-only**; reslicing window walk; **zig-only by design** — refuses js with a reasoned KORU161 (`grid.walk.kz:46`) |
| `pool` | **live** — transform (`keyword`) | decl sites in 697_021 + 115_045 (call-line grep incl. `-alloc`/`-free` overlap ~29) — **suite-only**; runtime-extent heap-backed grid |
| `pool-alloc` | **live** — transform | ~11 lines / 4 files — **suite-only** |
| `pool-free` | **live** — transform | ~6 lines / 4 files — **suite-only** |
| `slice` | **live** — declaration (`keyword\|declaration`, template) | **one call-line** — 697_023 is the only call in the reachable corpus; 3 more files mention it in comments |

Transform-target check (done-gate greps, run this session):
`grep -rn '"<torname>"' koru_std/*.kz src/*.zig` — **zero** emitted
`std/grid:`-spelled names outside the grid files themselves. Inside the organ,
`segs[0] = <declared grid name>` paths (grid.for.kz:287, grid.pool.kz:57,
grid.stored.kz:181, grid.sweep.kz:210, grid.walk.kz:205) point at program
declarations, not tor names. Segment-string scans exist but they *read*:
sibling transforms detect each other's sites by name
(`"for"`/`"sweep"` at grid.for.kz:134, `"for"`/`"sweep"`/`"walk"` at
grid.walk.kz:162, `"new"`/`"pool"` at grid.read.kz:94,192, `"slice"`/`"walk"`
at grid.slice.kz:66,83). No tor is reachable only through a rewrite — nothing
is `transform-target`, nothing `internal`, nothing `dead`.

## The hidden layer (surface no `std/grid:` spelling shows)

- **`0[<grid>]` index-typed fields** — a field typed by a grid's own name is
  a certified index into it (`nd: 0[tn]`), declared inside `new`'s field
  literal; consumer-visible surface with no tor (grid.idx.kz, pinned 697_022).
- **The minted-cursor wire** — `for`/`sweep` mint `__koru_gi_<grid>_L<line>`
  names; `stored` and the read lowering accept a write/read as floor-free
  *on the raw index text*. A cross-transform contract invisible to call-site
  grep (grid.cursor.kz).
- **`grid_slice.register` regbuf** — `walk` registers its cursors as borrows
  in a comptime-run buffer that `stored`'s slice-target path consults; a
  second wire, this one not even in the AST (grid.slice.kz:43).
- **`c.field` bare-binding in `sweep` arms** — rewritten to
  `<grid>[<cursor>].field` at source level so `stored` parses it; the
  read-side pass deliberately *skips* `std/grid` sites so a nested write's
  target stays source-shaped (grid.readwalk.kz header).
- **`[unsafe(bounds)]`** — annotation spelling on `new`/`pool`, waives the
  per-access `__koru_at` floor; measured motivation in grid.new.kz's header
  (boids steer loop: 187 ms trapped, 99 ms waived — the panic *edge*, not
  the check, is the cost).

## Ghosts — names in consumer sources that are not grid tors

- `std/grid:set`, `std/grid:count-nonzero` — **stale generation**: the
  pre-transform collection spelling (`| grid g |> set(g,x,y,v) |>
  count-nonzero(g) |> free(g)`) that 697_004's header documents as deleted.
  Lives on as a *live-surface citation* in `koru_std/field.kz:9` ("exactly
  parallel to std/grid:set / std/grid:count-nonzero") and a history note in
  810_061's header.

## Seams

- **`field.kz:9` cites deleted surface as a live parallel.** `set` /
  `count-nonzero` are gone by design — "count-nonzero is not a verb the grid
  owes anyone" (697_004 header) — but field.kz's ownership-model comment
  presents them as existing grid tors a reader could look up. **task** —
  one-line comment fix.
- **`for(0..<lit>, g)` with a literal range outrunning a literal `size:`
  refuses only at runtime.** `std/grid:for(0..9, cells)` on `size: 8` is
  `EXPECT_TRAP` (697_020): the check is emitted as a pre-loop panic by
  design, but both sides are statically knowable — the same class as
  `store:take`'s literal-index orphan. **→010** — a compile-time refusal for
  the literal-vs-literal case.
- **The `pool` family carries no phantom obligation — its own header admits
  it.** `pool-free` ("No phantom obligation this rung … That gap is named
  rather than hidden", grid.pool.kz:472-478): a second `pool-alloc`
  overwrites live column slices with no refusal (silent leak — the emitted
  body allocates unconditionally, grid.pool.kz:427); use-after-free only
  traps at runtime via `__koru_size = 0`. `take` mints `<taken!>`; `pool`
  mints nothing. **→010** — the obligation arm the family should have.
- **Stale cross-repo repro:** `koru-libs/dom/tests/frontier/
  grid_write_no_js_lowering.k` claims `std/grid:stored` has no JS lowering
  and the emitter panics `NoJsProcBody`. **Measured this session: stale.**
  The same program compiles `--lang=js` and emits a working write unit +
  `__koru_at` check (also pinned in-suite by 697_014, `LANGUAGES: zig js`).
  **→019** — retire or flip the repro; it narrates a fixed gap as current.
- **`[keyword]` affordance is unused.** `new`/`stored`/`sweep`/`pool`/`slice`
  are annotated so they can be invoked *without* module qualification
  (annotation_parser.zig:214) — zero unqualified spellings exist in the
  reachable corpus; every consumer writes `std/grid:`. The bare spellings
  are parser surface nobody exercises. **task** — decide whether the
  affordance stays; it reserves `stored { … }`/`sweep(…)` bare across every
  importing program.
- **Six of nine tors have zero non-suite reach.** `for`, `walk`, `slice`,
  `pool`, `pool-alloc`, `pool-free` are exercised only by the organ's own
  pin cluster (697_*) + 115_045; koru-libs — the only external consumer —
  uses `new`/`stored`/`sweep` only; orisha/DOOM/bend/koru-examples use none
  of it. Not dead (the suite is a consumer), but the surface was written
  ahead of pull. **task** — scope-vs-drift is a decision, not a finding;
  recorded here for 009's dedupe intake.

## Verdict

Designed in its bones — every tor is a transform with a KORU161 wall and a
header that argues for its own shape, and its hidden layer is deliberate
wiring rather than accreted debris — but the surface outran its market:
three of nine tors carry all consumer mass, and the rest live on the
strength of their own pins.
