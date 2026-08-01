// PINS O10.iii ACROSS A REMOVAL on the self-FK substrate (690_048's missing
// half): a handle STORED IN A COLUMN keeps naming its row after another row's
// take relocates that row. `a.next` points at c; taking b swap-moves c into
// b's old dense position; following `nodes[a.next]` must land on c AT ITS NEW
// POSITION — the write reaches the row that holds 300, wherever it now sits.
//
// 690_048 pinned the follow with no removal in the program, which is why the
// raw-position lowering passed it; this is the same follow with the swap that
// distinguishes a handle from a position.
import std/io
import std/store

std/store:new(nodes, capacity: 64) { val: i64, next: i64 }

std/store:insert(nodes) { val: 100, next: -1 }
| row a |> std/store:insert(nodes) { val: 200, next: -1 }
    | row b |> std/store:insert(nodes) { val: 300, next: -1 }
        | row c |> std/store:stored { nodes[a].next: c }
            |> std/store:take(nodes[b])
                | item gone |> std/io:print.ln("took {{ gone.val:d }}")
                    |> std/store:stored { nodes[a.next].val: 777 }

std/store:sweep(nodes)
! sweep e |> std/io:print.ln("val {{ e.val:d }}")
