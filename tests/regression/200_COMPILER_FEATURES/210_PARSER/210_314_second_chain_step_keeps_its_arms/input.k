// PINS: when a chain step's branch arms are written on following lines, each
// arm binds to the step directly above it — not to an earlier step in the
// same chain.
//
// `|> if (g.tick == 0)` and `|> if (g.tick == 1)` are sibling links of one
// chain inside the `! first` arm, and each declares `| then`. Before the fix
// the flat multi-line list [then, if, then, print] was dumped whole under the
// first `|> if`, so the second `if` saw no `then` (KORU022) and the first saw
// two (KORU028). The fold must interleave: arms attach to the current chain
// tail, unnamed `|>` steps extend the chain and become the new tail.
//
// tick = 0: the first `if` fires ("one"), the second does not, and the chain
// continues to "end" — the run pins both the attachment and the order.

import std/io
import std/store

std/store:new(s, capacity: 4) { tick: i32 }
std/store:insert(s) { tick: 0 }

std/store:query(s)
! first g |> std/io:print.ln("a")
    |> if (g.tick == 0)
        | then |> std/io:print.ln("one")
    |> if (g.tick == 1)
        | then |> std/io:print.ln("two")
    |> std/io:print.ln("end")
