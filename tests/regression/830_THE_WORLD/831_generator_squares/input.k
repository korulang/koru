// The World in Koru — generators, entry 1.
// Doorway: Python's `def squares(n): for i in range(n): yield i*i`.
// Here in Koru: `squares` is an effect-bearing event whose subflow FIRES
// `! each` per element — a generator whose control flow is the type. The
// consumer drives it lazily, one yielded value at a time.
import std/io
import std/control

pub event squares { n: usize }
! each usize
| done usize

squares = for(0..n)
! each i |> each(i * i)
| done => done n

squares(n: 5)
! each s |> std/io:print.ln("{{ s:d }}")
| done _ |> _
