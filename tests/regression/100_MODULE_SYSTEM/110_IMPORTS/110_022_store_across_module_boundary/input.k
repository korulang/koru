// A store declared in the entry file is REACHABLE from an imported module, in
// both directions. Store names are program-global, but the cell and the
// synthesized accessors are emitted into the declaring module alone, so each
// direction has to cross a namespace to get to them:
//
//   module WRITES  the write tor lives where the store was DECLARED, not where
//                  the write is written — the call qualifies with the store's
//                  home module.
//   module READS   the cell is a module-scope var in the declaring module's
//                  emitted struct, so the rewrite carries that namespace as a
//                  prefix instead of naming it bare.
//
// The REACH is what this pins. The other half of the original failure was not
// about modules at all — a produce arm could not read a cell anywhere, in one
// file or many — and is pinned at its own position by 690_078. Both are needed:
// each stays green while the other breaks.
//
// Why it matters: with 110_021 this is what lets an app be decomposed. A TUI's
// per-page vocabulary is `name = cond(ch)` over stores those tors mutate, so
// value-only modules were as far as decomposition went.
//
// Not covered here, and walled loudly in std/store rather than guessed: a store
// declared in one imported module and read from a DIFFERENT one, which needs
// the emitter's module-path mangling.
import std/io
import std/store
import app/ops

std/store:new(s) { v: 7[i64] }

app/ops:bump() |> app/ops:peek(): a |> std/io:print.ln("v={{ a:d }}")
