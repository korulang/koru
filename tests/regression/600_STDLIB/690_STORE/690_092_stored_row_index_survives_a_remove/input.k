// PINS: a row index parked in a store cell must not be silently invalidated by
// a removal elsewhere in the store.
//
// MEASURED 2026-07-28 — the write below goes NOWHERE, with no diagnostic:
//
//   rows are [100@0, 200@1, 300@2]; `sel.at` remembers row c (index 2)
//   `take(nodes[a])` removes index 0, and take is SWAP-REMOVE (store.kz:2717),
//   so row 2 moves into slot 0 and len becomes 2
//   `stored { nodes[sel.at].val: 999 }` writes through index 2 — now past the
//   live length, inside capacity, so nothing traps
//   the sweep then prints `300, 200`. The 999 is not in the store, and no
//   error was raised.
//
// This is the first program in the corpus to combine a STORED row index with a
// REMOVAL. Both halves are separately pinned and green — `todos[ui.sel]` at
// 690_075/076, `nodes[a].next` at 690_048, the synthesized `[tree]` parent
// column at 695_001/002, and take at 690_016 — and no test had ever put the two
// in one program, which is why this has never surfaced.
//
// DISPOSITION IS OPEN. This pin encodes the stable-handle reading: the row that
// held 300 receives the write. If the ruling is instead that a stored index is
// not a thing a program may hold, this becomes a MUST_ERROR naming the refusal,
// and the expectation below is wrong on purpose until then.
import std/io
import std/store

std/store:new(sel) { at: 0[i64] }
std/store:new(nodes, capacity: 8) { val: i64 }

std/store:insert(nodes) { val: 100 }
| row a |> std/store:insert(nodes) { val: 200 }
    | row b |> std/store:insert(nodes) { val: 300 }
        | row c |> std/store:stored { sel.at: c }
            |> std/store:take(nodes[a])
                | item _ |> std/store:stored { nodes[sel.at].val: 999 }
                | empty |> std/io:print.ln("empty")

std/store:sweep(nodes)
! sweep n |> std/io:print.ln("row val {{ n.val:d }}")
