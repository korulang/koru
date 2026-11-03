// PINS O10.iii's take half: a handle parked in a store cell keeps naming
// its row across another row's take — and stays valid as a TAKE ADDRESS,
// not only as a stored-write target. 690_092 pins the write-through after
// a different row's removal; 690_075 pins take-through-parked-handle with
// no removal in the program. This is the join both miss: park d's handle,
// take a (swap-remove moves d into a's old dense slot), then take THROUGH
// the parked handle — the | item payload must be d's (400), and the
// survivors exactly b and c.
//
// The distinguishing shape: after a's take, dense is [d, b, c] with len 3.
// A positional reading of the parked handle ("3") indexes past len — the
// second take answers | empty and three rows survive. Under the
// identity-over-position ruling (2026-08-02, 690_075) the handle follows
// the row to its new dense position and take yields the moved row itself.
import std/io
import std/store

std/store:new(sel) { at: -1[i64] }
std/store:new(nodes, capacity: 8) { val: i64 }

std/store:insert(nodes) { val: 100 }
| row a |> std/store:insert(nodes) { val: 200 }
    | row b |> std/store:insert(nodes) { val: 300 }
        | row c |> std/store:insert(nodes) { val: 400 }
            | row d |> std/store:stored { sel.at: d }
                |> std/store:take(nodes[a])
                    | item gone |> std/io:print.ln("took {{ gone.val:d }}")
                    | empty |> std/io:print.ln("a-empty")

std/store:take(nodes[sel.at])
    | item gone |> std/io:print.ln("parked took {{ gone.val:d }}")
    | empty |> std/io:print.ln("parked empty")

std/store:query(nodes)
! query n |> std/io:print.ln("val {{ n.val:d }}")
