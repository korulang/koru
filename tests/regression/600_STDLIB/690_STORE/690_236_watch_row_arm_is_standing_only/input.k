// `std/store:watch(s) ! row <bind>` — the ROW-scoped standing rule, and the
// corner of the store surface that was missing.
//
// Row-scoped sites vary on two independent axes, and only two of the three
// corners had a spelling:
//
//               | standing subscription | sweeps at its site
//   `query`     |          yes          |      yes  (linear)
//   `preorder`  |          no           |      yes  (DFS)
//   `watch !row`|          yes          |      NO      <- this test
//
// `query` fused both halves, which is why the verb that SOUNDS like a read was
// the one that could not sit in a nested position, while the momentary read was
// called `sweep`. Splitting the standing half out under `watch` — where every
// other reactive rule already lives — frees `query` to mean the read.
//
// What this pins is the SEPARATION, not merely that it compiles: `n: 1` is
// inserted BEFORE the watch and must NOT fire, because a watch has no program
// position to read from. Only the two rows written after it react. A fused
// implementation prints three lines.
//
// The arm names what you are watching: a column by its name (`! hp h`), or
// `row` for the whole row. A store that genuinely HAS a column called `row`
// keeps it — the field lookup runs first, so no existing program changes
// meaning.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: 0[i64], n: 0[i64] }

std/store:insert(todos) { done: 0, n: 1 }
| row _ |> _
| full |> _

std/store:watch(todos)
! row e |> std/io:print.ln("reacted n={{ e.n:d }}")

std/store:insert(todos) { done: 1, n: 2 }
| row _ |> _
| full |> _

std/store:insert(todos) { done: 0, n: 3 }
| row _ |> _
| full |> _
