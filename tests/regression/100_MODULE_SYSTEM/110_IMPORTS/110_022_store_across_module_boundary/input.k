// RED BY DESIGN (pinned 2026-07-25). A store declared in the entry file is
// invisible to an imported module — in BOTH directions, and each fails its own
// way:
//
//   module READS  `s.v`                      -> raw Zig: "use of undeclared
//                                               identifier 's'". The reference
//                                               is never rewritten to
//                                               __koru_store_s. A host leak.
//   module WRITES `std/store:stored {s.v: …}` -> error[KORU040]: unknown tor
//                                               'ops:__store_write_s'. The
//                                               synthesized write tor is looked
//                                               up in the MODULE's namespace.
//
// Same axis as 110_021 (fixed by 50182722): entry vs imported module. Keyword
// tors used to misresolve that way; store references still do. Store NAMES are
// program-global for the transform's own lookup — which is why `std/store(name)`
// attach works program-wide — but the synthesized accessors are emitted into the
// declaring module only.
//
// Why it matters: it is the second half of "can an app be decomposed". With
// 110_021 green, koru-examples' gallery key vocabulary parses fine in a module
// — every tor there is `name = cond(ch)` — and then dies on the stores those
// tors mutate. So a TUI app is STILL one file, for a different reason than it
// was this morning. Value-only modules already work (koru-examples/ledger,
// gallery/content); what cannot move is any flow that touches program state.
import std/io
import std/store
import app/ops

std/store:new(s) { v: 7[i64] }

app/ops:bump() |> app/ops:peek(): a |> std/io:print.ln("v={{ a:d }}")
