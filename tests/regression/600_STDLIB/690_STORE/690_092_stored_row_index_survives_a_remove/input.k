// PINS O10.iii (690_STORE/DESIGN.md): a row handle parked in a store cell
// keeps naming its row across another row's removal — the stable-handle
// reading, ruled 2026-07-31.
//
// The adversarial shape: `sel.at` remembers row c (300); `take(nodes[a])`
// swap-removes, relocating c into a's old dense position; the write through
// `sel.at` must land on c WHEREVER IT NOW SITS — the sweep prints 999 where
// 300 was, then 200. A raw-position reading writes past len instead, silently
// (that corruption is what this test surfaced, 2026-07-28).
//
// This was the first program in the corpus to combine a STORED row handle with
// a REMOVAL — the no-removal halves are 690_075/076, 690_048, 695_001/002 and
// 690_016; the removal halves of those are 690_117 and 695_004, and the
// stale-handle traps are 690_115/116.
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

std/store:query(nodes)
! query n |> std/io:print.ln("row val {{ n.val:d }}")
