// `[id]` ON A `preorder` ARM — the tree-walk twin of 690_247.
//
// `preorder` rides the same qrow/qbody machinery as a standing rule (TT5), so
// the request block admitted on a rule arm 2026-08-03 lands here by the same
// route. The gate's clause 1 asks whether the SITE knows something the ROW does
// not; a preorder site knows which row it has reached, and the row cannot name
// itself. `[ordinal]` stays refused here for the same reason it is refused on a
// rule (690_248) — a pre-order walk does have an order, but nothing in the
// current lowering carries a position, so admitting it would be a promise the
// site cannot keep. That refusal is the "meaningless-or-unimplemented" line the
// gate's SITE wording exists to keep visible; if a workload ever wants a
// pre-order position it arrives as evidence, the way `[id]` did.
//
// Note the spelling: the annotation is `[row]`, not `[preorder]`. The arm names
// what the site FIRES; the request names what the site SYNTHESIZES, and the row
// is the row on every arm that has one.
//
// Tree:            root(10)
//                    `-- a(20)
//                         `-- c(40)
// The first walk marks c's HANDLE into a sibling store; the top-level write
// then follows that stored handle and lands on c. If `[id]` handed out a
// position this would still pass here — nothing moves — which is exactly why
// 690_247 carries the swap-remove half. This pin is the tree-walk admission;
// that one is the retention proof.
import std/io
import std/store

[tree]std/store:new(tree, capacity: 64) { val: i64 }
std/store:new(mark, capacity: 1) { who: 0[i64] }

std/store:insert(tree) { val: 10 }
| row root |> std/store:insert(tree) { val: 20 }
    | row a |> std/store:insert(tree) { val: 40 }
        | row c |> std/store:stored { tree[a].parent: root }
            |> std/store:stored { tree[c].parent: a }

std/store:preorder(tree)
! preorder { [row]e, [id]h } when e.val == 40 |> std/store:stored { mark.who: h }

std/store:stored { tree[mark.who].val: 999 }

std/store:preorder(tree)
! preorder e |> std/io:print.ln("val {{ e.val:d }}")
