// PINS O10.iv's HANDLE-SAFETY FLOOR (690_STORE/DESIGN.md), read half: an
// indexed field READ (`nodes[a].val` on an expression's value side, the
// 690_076 lowering) through a taken row's handle traps. This is the path
// DESIGN.md's adversary called the true silent-wrong-answer risk — a read
// that skips the generation compare returns another row's data with no
// diagnostic. The floor is the compare; elision must be PROVEN, not skipped.
import std/io
import std/store

std/store:new(nodes, capacity: 8) { val: i64 }
std/store:new(out) { v: 0[i64] }

std/store:insert(nodes) { val: 100 }
| row a |> std/store:insert(nodes) { val: 200 }
    | row b |> std/store:take(nodes[a])
        | item gone |> std/io:print.ln("took {{ gone.val:d }}")
            |> std/store:stored { out.v: nodes[a].val }
