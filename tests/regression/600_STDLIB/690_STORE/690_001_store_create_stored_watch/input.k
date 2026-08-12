// ASPIRATIONAL (RED by design until std/store rung 1 lands — see DESIGN.md).
// The hello-store: create / stored / watch, the singleton (one-row) case.
//
// - `std/store:new(game) { entities: 0[i64] }` — comptime declaration
//   (name + shape) and program-long instantiation in one top-level form,
//   modeled on `std/kernel:shape(Body) { ... }` (name arg + source block)
//   and capture's seed block `{ oval: 0[i32] }` (320_036). A top-level
//   store is the degenerate extent: born empty-at-start, lives forever —
//   no attach/backfill question exists (DESIGN.md, adversary verdicts).
// - `std/store:watch(game) ! entities e |> ...` — a subscription. The
//   effect branch is named by FIELD; it fires on every write to that
//   field, compiled tap-style into the store's write path (producer owns
//   the if; NO runtime registry). Placement of the watch is organizational
//   only.
// - `std/store:stored { game.entities: ... }` — the sole write path.
//   Block shape grounded on `captured { oval: outer.oval + ires.ival }`
//   (320_036): opaque source block, store's own projector interprets it.
//
// Two writes → the watch fires twice, synchronously with the write
// (interleave-not-overlap; DESIGN.md ruling queue (h) lean).
// ASSUMES the creation seed does NOT fire watches (birth-is-not-a-write —
// DESIGN.md O9, lean pending ratification): output starts at 1, no
// "entities: 0" line.

import std/io
import std/store

std/store:new(game) { entities: 0[i64] }

std/store:watch(game)
! entities e |> std/io:print.ln("entities: {{ e:d }}")

std/store:stored { game.entities: game.entities + 1 }
std/store:stored { game.entities: game.entities + 1 }
