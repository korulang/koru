// PINS: a store transform nested inside a `! preorder` arm sees the row the arm
// walks — the `! preorder` twin of 690_008, which pins this for `! query`.
//
// `preorder` carries the ambient `entity`, and a nested `std/store:stored` names
// its field. The nested transform must not be rewritten before `preorder` has
// resolved what `entity` is: `stored` would look up a store by that literal name,
// find none, and refuse — about a program state `preorder` is one step from
// fixing. That is what `claims_descendants` exists to prevent, and it is why the
// same shape works under `! sweep`.
//
// Tree:            root(10)
//                   |-- a(20)
//                   |    `-- c(40)
//                   `-- b(30)
// Pre-order walk:  10, 20, 40, 30  →  each incremented once  →  11, 21, 41, 31
import std/io
import std/store

[tree]std/store:new(tree, capacity: 64) { val: i64 }

std/store:insert(tree) { val: 10 }
| row root |> std/store:insert(tree) { val: 20 }
    | row a |> std/store:insert(tree) { val: 30 }
        | row b |> std/store:insert(tree) { val: 40 }
            | row c |> std/store:stored { tree[a].parent: root }
                |> std/store:stored { tree[b].parent: root }
                |> std/store:stored { tree[c].parent: a }

// The nested write is the pin: it names `entity.val`, which only means anything
// once `preorder` has bound the row.
std/store:preorder(tree)
! preorder e |> std/store:stored { e.val: e.val + 1 }

std/store:preorder(tree)
! preorder e |> std/io:print.ln("{{ e.val:d }}")
