// Pins `glance`: `koruc input.k glance` prints the declaration surface of the
// whole program — every module's events with full signatures, annotations, and
// file:line. glance is a built-in FRONTEND AST mode (no import, no backend): it
// walks the fully-resolved post-import AST and exits, like --help. `--app` drops
// std/koru. This file imports std/store, so glance must surface its CRUD events.
import std/store

std/store:new(counter) { clicks: 0[i64] }

std/store:watch(counter)
! clicks c |> std/store:stored { counter.clicks: counter.clicks + 1 }
