// PINS O10.iii ACROSS A REMOVAL in the [tree] substrate: parent handles keep
// naming the same rows after a take swap-relocates one. Taking leaf b (30)
// moves c (40) into b's old dense position; c's stored `parent` still names a,
// and the preorder walk resolves it there — the forest topology is unchanged
// by where rows physically sit.
//
//   root(10) ── a(20) ── c(40)      b(30) taken; c relocated by the swap
//
// Preorder after the take: 10, 20, 40. A position-based parent column would
// have orphaned or rewired c the moment the swap moved it.
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
                |> std/store:take(tree[b])
                    | item gone |> std/io:print.ln("took {{ gone.val:d }}")

std/store:preorder(tree)
! preorder e |> std/io:print.ln("{{ e.val:d }}")
