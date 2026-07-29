// 695_002 — [tree] store TT2: a reparent that would create a CYCLE is REJECTED
// by a default-on guard; the `| cycle` branch handles it (mirrors insert's
// `| full`). The bad write is refused, the tree stays intact.
// chain root(10) -> a(20) -> b(30); then attempt to make root a child of b.
// b is in subtree(root) (root->a->b), so root->a->b->root would be a cycle →
// the `| cycle` branch fires, the write is refused, preorder still walks 10/20/30.
// (The `| cycle` arm starts on its own line — inline continuations are not
// Koru; that grammar law is pinned at 210_043.)
import std/io
import std/store

[tree]std/store:new(tree, capacity: 64) { val: i64 }

std/store:insert(tree) { val: 10 }
| row root |> std/store:insert(tree) { val: 20 }
    | row a |> std/store:insert(tree) { val: 30 }
        | row b |> std/store:stored { tree[a].parent: root }
            |> std/store:stored { tree[b].parent: a }
            |> std/store:stored { tree[root].parent: b }
                | cycle |> std/io:print.ln("cycle rejected")

std/store:preorder(tree)
! preorder e |> std/io:print.ln("{{ e.val:d }}")
