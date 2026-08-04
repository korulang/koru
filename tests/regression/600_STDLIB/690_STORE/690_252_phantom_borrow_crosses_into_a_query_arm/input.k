// PINS: a phantom-typed BORROW minted outside a sweep is usable INSIDE
// `std/store:query`'s arm.
//
// `xs` is a `<list!>` handle from `| list xs`. The arm pushes to it once per
// row and reads its length back, so the output proves it is the SAME list
// accumulating — 1, 2, 3 — and not a fresh one per iteration.
//
// This was refused, and the store's sweep was the ONLY construct that refused
// it. The same borrow threads into `for(0..N) ! each` and into
// `std/fs:read-lines`' `! line` arm, where 810_242_day24_part2 has pushed regex
// captures into a list for weeks.
//
// THE CAUSE WAS NOT THE LOWERING, which is what made it worth chasing rather
// than working around. A sweep body is transplanted into a separate event
// (`__store_sweepbody_<s>_L<n>`) whose inputs carry the captures the body
// references, and that threading ALREADY worked — a plain `i64` bound outside
// the sweep arrives inside it correctly. What it dropped was the phantom:
// `lookupBranchIn` read the branch payload's type and module and left its
// `<state!>` behind, so the synthesized input declared a bare type and the
// checker, correctly, saw a name with no tracked state.
//
// Three things had to be right and each one produced its own diagnostic on the
// way, which is worth recording because they read like unrelated bugs:
//
//   phantom dropped      -> "argument 'xs' has no tracked phantom state"
//   phantom kept as-is   -> KORU033, "Cannot issue obligation '<list!>' on
//                           input parameter" — an input may BORROW a state but
//                           never mint one
//   phantom unqualified  -> "expected 'std.list:list' but got '<prog>:list'",
//                           the state resolving against the consumer's module
//
// So the capture now carries the payload's obligation, qualified with the
// module that declared it, and the synthesized input demotes it to a bare
// borrow — the same demotion an owned column's projection already made. The arm
// may read and mutate the handle; it must not be asked to DISCHARGE it, because
// the obligation belongs to the enclosing scope and the body runs once per row.
//
// KNOWN REMAINING GAP: this uses `new-i64`, the concrete constructor. Going
// through `std/list:new(i64)` — a `[comptime|transform]` that rewrites to it —
// still fails, because the capture collector reads branches off the invocation
// path and the transform event declares none. That is a transform-ordering
// question, narrower than this one, and not fixed here.
import std/io
import std/store
import std/list

std/store:new(items, capacity: 8) { v: i64 }

std/store:insert(items) { v: 10 }
| row _ |> _
std/store:insert(items) { v: 20 }
| row _ |> _
std/store:insert(items) { v: 30 }
| row _ |> _

std/list:new-i64()
| list xs |> std/store:query(items)
    ! query e |> std/list:push(xs, e.v) |> std/list:len(xs): n |> std/io:print.ln("pushed {{ e.v:d }}, len {{ n:d }}")
| err _ |> std/io:print.ln("list failed")
