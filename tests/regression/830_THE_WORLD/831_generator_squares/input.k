// The World in Koru — generators, entry 1.
// Doorway: Python's `def squares(n): for i in range(n): yield i*i`.
// Here in Koru: `squares` is an effect-bearing event whose subflow FIRES
// `! each` per element — a generator whose control flow is the type. The
// consumer drives it lazily, one yielded value at a time. Terminal is void
// `| done` — a pure yielding generator hands back no summary.
import std/io

pub tor squares { n: usize }
! each usize
| done

squares = for(0..n)
! each i |> each(i * i)
| done => done

squares(n: 5)
! each s |> std/io:print.ln("{{ s:d }}")
| done |> _
