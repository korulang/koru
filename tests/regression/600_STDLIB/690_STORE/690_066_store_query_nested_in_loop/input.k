// ASPIRATIONAL (RED by design) — pins the "top-level-only" transform-lowering
// class for std/store:query. See memory: nested-transform-lowering-gap.
//
// std/store:query is the only row-iteration primitive, and it is a
// TOP-LEVEL-ONLY comptime transform: it resolves its store by scanning
// top-level program items. Invoked in a NESTED position (here a `! each`
// for-loop body; equally a vaxis `! draw` / `! key` handler body) it fails to
// resolve the store — EVEN THOUGH `items` is declared `capacity: 8` right above.
//
// Top-level `query` composes (690_005). Only the nested position breaks, which
// is the tell that store-discovery, like the transform pass, is position-limited.
//
// ACTUAL today: BACKEND_COMPILE_ERROR — "std/store:query(items): unknown store -
//   no std/store:new(items) found" — which is ALSO a misleading diagnostic: the
//   store IS declared; the real constraint is "query can't resolve from a nested
//   position". Flips GREEN when nested transforms compose uniformly.
//
// EXPECTED: the 2 rows swept on demand on each of the 2 loop iterations.

import std/io
import std/store

std/store:new(items, capacity: 8) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }

for(0..2)
! each _ |> std/store:query(items)
    ! query { entity.v } |> std/io:print.ln("v {{ v:d }}")
