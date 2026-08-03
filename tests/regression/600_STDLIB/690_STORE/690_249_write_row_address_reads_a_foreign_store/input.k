// A WRITE'S ROW ADDRESS MAY READ ANOTHER STORE — the write side catching up to
// the read side by one hop.
//
// Reads have composed to arbitrary depth since 690_245: `a[b[c].h].v` lowers all
// the way down. Writes stopped at one hop, and the failure was silent until the
// emitted Zig refused to compile:
//
//   std/store:stored { target[r.h].v: 99 }   // r is a sweep binding over `refs`
//   -> target[refs[__koru_sdix_r_L16].h].v   // `refs` with no __koru_store_ prefix
//   -> error: use of undeclared identifier 'refs'
//
// THE CAUSE, and it is a nice one: a row-addressed lvalue is two different
// things spelled as one string. `target[...]` and `.v` are a write TARGET, in
// Koru spelling, which the `stored` transform re-parses by splitting on the
// brackets. But whatever sits BETWEEN the brackets is a READ. The rewriter
// applied the target form to the whole string, so the index came out in Koru
// lvalue spelling in a position where nothing downstream re-lowers it. The head
// is a target; the subscript is a read; they need different forms.
//
// The splitter takes the FIRST `[` and the LAST `]`, so a fully lowered read
// nested inside the brackets survives the re-parse unharmed.
//
// WHY IT MATTERS BEYOND TIDINESS: this is the scatter step of every spatial
// workload — visit one corpus, accumulate into another addressed by something
// the visited row carries. A flocking sim's bucket rebuild is exactly this
// shape, and it could not be written at all before this.
import std/io
import std/store

std/store:new(target, capacity: 8) { v: i64 }
std/store:new(refs, capacity: 8) { h: i64 }

std/store:insert(target) { v: 1 }
| row t |> std/store:insert(refs) { h: t }
    | row _ |> _
    | full |> _
| full |> _

// The sweep visits `refs`; the write lands in `target`, at an address the
// visited row holds. Two stores, one arm, one hop through a column.
std/store:query(refs)
! query r |> std/store:stored { target[r.h].v: 99 }

std/store:query(target)
! query e |> std/io:print.ln("v {{ e.v:d }}")
