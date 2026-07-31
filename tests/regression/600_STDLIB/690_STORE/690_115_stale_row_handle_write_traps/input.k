// PINS O10.iv's HANDLE-SAFETY FLOOR (690_STORE/DESIGN.md), write half: a
// `stored` write through the handle of a row that was TAKEN traps, naming the
// store. The generational check is one compare per access; without it this
// exact program was 690_092's silent corruption — the write landed past len
// but inside capacity and nothing said a word.
//
// `a` is taken, so `nodes[a]` no longer addresses anything. The row that DID
// move into a's old dense position (200) must not receive the write — position
// is not identity (O10.iii), and a dead handle answers loudly, not by proxy.
import std/io
import std/store

std/store:new(nodes, capacity: 8) { val: i64 }

std/store:insert(nodes) { val: 100 }
| row a |> std/store:insert(nodes) { val: 200 }
    | row b |> std/store:take(nodes[a])
        | item gone |> std/io:print.ln("took {{ gone.val:d }}")
            |> std/store:stored { nodes[a].val: 999 }
