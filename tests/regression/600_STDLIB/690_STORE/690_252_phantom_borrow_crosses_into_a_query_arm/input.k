// RED ON PURPOSE. A phantom-typed BORROW minted outside a sweep cannot be used
// INSIDE `std/store:query`'s arm, and the store's sweep is the only construct in
// the language with that restriction.
//
// Here `xs` is a `<list>` borrow from `| list xs`. Pushing to it from inside the
// query arm is refused:
//
//     error[KORU030]: Phantom state mismatch: argument 'xs' has no tracked
//     phantom state, but this event requires state '<list>'.
//
// THE SAME BORROW, THE SAME PUSH, IN TWO OTHER SWEEPS, BOTH FINE:
//
//   - `std/fs:read-lines` / `! line` — 810_242_day24_part2 pushes regex
//     captures into exactly this kind of list from inside the line arm, and it
//     is GREEN. Nothing about a list borrow forbids this.
//   - `for(0..N)` / `! each` — a counted loop over a grid, pushing each cell's
//     value, compiles today.
//
// So the restriction is not "phantom borrows cannot enter sweep bodies". It is
// specific to `std/store:query`, which is the language's flagship data
// operation and the one place a user is most likely to want a resource.
//
// THE MECHANISM, as far as it has been traced: a `for` body is emitted as an
// INLINE BLOCK — the frame/list binding is referenced straight out of the
// enclosing scope. A store sweep body is lifted into a DETACHED EVENT HANDLER
// and invoked per row, so an outer binding reaches it only as a declared input,
// and a phantom-typed one has no way to be declared there. `std/fs:read-lines`
// evidently keeps its arm inline; `std/store:query` does not.
//
// THE DIAGNOSTIC ALSO MISDESCRIBES IT, which is the smaller half of this bug and
// the cheaper one to fix. "has no tracked phantom state" says the value never
// had one. It did — `std/list:len(xs)` at the same level as the query type-checks
// fine. The state was LOST AT A BOUNDARY, and the message should say which
// boundary. Its sibling branch in `phantom_semantic_checker.zig` was already
// taught this lesson ("say so, don't blame it for a checker blind spot",
// ~line 3190, the `<state!>` consumption case); the requirement case at ~3200
// still emits the flat message.
//
// Found while trying to draw one rectangle per row with `libs/raylib` — the
// frame borrow hits this identically, which is why that library's `bounce.k`
// can clear the screen but cannot draw an entity. Its header blames the
// ambient-context wall for standing RULES (690_006); this is a second, distinct
// path to the same dead end, and the `for` and `read-lines` cases say it is not
// a necessary one.
//
// Flip to green when a store sweep arm can use an outer phantom borrow. Expected
// output is what the program plainly means: two rows pushed, length 2.
import std/io
import std/store
import std/list

std/store:new(items, capacity: 8) { v: i64 }

std/store:insert(items) { v: 10 }
| row _ |> _
| full |> _
std/store:insert(items) { v: 20 }
| row _ |> _
| full |> _

std/list:new(i64)
| list xs |> std/store:query(items)
    ! query e |> std/list:push(xs, e.v)
| err _ |> std/io:print.ln("list failed")

std/io:print.ln("pushed")
