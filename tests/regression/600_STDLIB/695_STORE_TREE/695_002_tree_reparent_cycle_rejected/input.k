// 695_002 — [tree] store TT2: a reparent that would create a CYCLE must be
// REJECTED, not silently corrupt the forest. ASPIRATIONAL (see TODO) — no cycle
// guard exists yet; today the `tree[root].parent: b` write is silently accepted
// and preorder emits NOTHING (no row left with parent == -1 → no roots).
// chain root(10) -> a(20) -> b(30); then attempt to make root a child of b.
// b is in subtree(root) (root->a->b), so root->a->b->root is a cycle.
import std/io
import std/store

[tree]std/store:new(tree) { val: i64 }

std/store:insert(tree) { val: 10 }
| row root |> std/store:insert(tree) { val: 20 }
    | row a |> std/store:insert(tree) { val: 30 }
        | row b |> std/store:stored { tree[a].parent: root }
            |> std/store:stored { tree[b].parent: a }
            |> std/store:stored { tree[root].parent: b }

std/store:preorder(tree)
! preorder { entity.val } |> std/io:print.ln("{{ val:d }}")
