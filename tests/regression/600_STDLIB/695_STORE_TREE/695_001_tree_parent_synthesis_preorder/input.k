// 695_001 — [tree] store: TT1 (parent synthesis is invisible) + TT5 (forest,
// deterministic preorder). The head acceptance pin of the tree-store spec.
//
// PINS what `[tree]` delivers, on the self-FK substrate (690_048): a row handle
// IS an i64 row index, -1 = unset/root, and `store[a.next]` follows a
// handle-carrying column one hop.
//
// What `[tree]` does (the thin lens, per DESIGN.md):
//   1. Synthesize an INVISIBLE canonical `parent` column — a self-FK i64,
//      -1 = root. The user row shape below declares NO parent field (TT1).
//   2. A node's parent is set by writing the synthesized `parent` via the
//      landed self-FK `stored` write — `stored { tree[c].parent: p }` — so the
//      tree reuses 690_048 rather than inventing a parallel index.
//   3. Expose `preorder` — a depth-first pre-order walk over the forest. Roots
//      (parent == -1) in insertion order; siblings in insertion order (the
//      unordered-core default; explicit z/sibling-order is a later thesis).
//
// The surface this pins:
//   - [tree]std/store:new(...)            annotation → parent synthesis + traversal
//   - std/store:preorder(name) / ! preorder { ... }   DFS pre-order arm
//
// Tree built:      root(10)
//                   |-- a(20)
//                   |    `-- c(40)
//                   `-- b(30)
// Preorder walk:   10, 20, 40, 30
//   (DFS pre-order — NOT insertion 10 20 30 40, NOT BFS 10 20 30 40;
//    40-before-30 is what proves it is genuine pre-order, not either of those.)
import std/io
import std/store

[tree]std/store:new(tree, capacity: 64) { val: i64 }

// Insert four nodes (parent starts at the -1 root sentinel, synthesized), then
// attach three of them by setting the synthesized self-FK `parent` — the exact
// 690_048 stored-write, now against the tree's hidden column.
std/store:insert(tree) { val: 10 }
| row root |> std/store:insert(tree) { val: 20 }
    | row a |> std/store:insert(tree) { val: 30 }
        | row b |> std/store:insert(tree) { val: 40 }
            | row c |> std/store:stored { tree[a].parent: root }
                |> std/store:stored { tree[b].parent: root }
                |> std/store:stored { tree[c].parent: a }

// Pre-order walk of the forest → deterministic label sequence.
std/store:preorder(tree)
! preorder e |> std/io:print.ln("{{ e.val:d }}")
