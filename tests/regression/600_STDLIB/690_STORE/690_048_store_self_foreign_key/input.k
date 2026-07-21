// 690_048 — store SELF-FOREIGN-KEY: a field holds a handle to another row of
// the SAME store, and the reference round-trips.
//
// This is the SUBSTRATE for a future tree/forest store (DESIGN ruling 9,
// "foreign keys — rows reference rows"). A PLAIN plural store, no tree
// annotation: `next` is a self-FK column typed i64 (a row handle IS an i64 row
// index). It holds the -1 sentinel (unset) until pointed at a row;
// `stored { nodes[a].next: b }` sets it to another row's handle (b from
// `| row b`). The reference round-trips two ways: the handle is read back via
// `query` (entity.next), AND it is FOLLOWED to address the referenced row via
// the self-FK head `store[a.next]` (built 2026-07-20 — the bracket head derefs
// a handle-carrying column of the same store to a row index, one hop).
import std/io
import std/store

std/store:new(nodes, capacity: 64) { val: i64, next: i64 }

// parent (row a) and child (row b); `next` starts at the -1 sentinel (unset).
// First `stored` sets a.next to b's handle. Second `stored` FOLLOWS the ref:
// `nodes[a.next]` is the row a.next points at (child b), so it mutates the
// child's val THROUGH parent a's self-FK — proving the field-value derefs to a row.
std/store:insert(nodes) { val: 100, next: -1 }
| row a |> std/store:insert(nodes) { val: 200, next: -1 }
    | row b |> std/store:stored { nodes[a].next: b }
        |> std/store:stored { nodes[a.next].val: 777 }

std/store:query(nodes)
! query { entity.val, entity.next } when val > 0 |> std/io:print.ln("val {{ val:d }} next {{ next:d }}")
