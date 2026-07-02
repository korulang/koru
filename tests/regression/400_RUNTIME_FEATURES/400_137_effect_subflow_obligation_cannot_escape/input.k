// SUBFLOW-IMPLEMENTED EFFECTS, obligations, no-escape negative (pure .k, no
// proc) — the subflow sibling of 400_103, the discriminator. `! each` carries
// no <state!> resume, so an obligation born in the consumer's handler CANNOT
// escape the firing. Here the handler creates a <field!> obligation
// (std/field:new) and never frees it — unbalanced, and it must be rejected
// with KORU030 even though the generator is a pure-Koru subflow. If this is
// silently accepted, obligation tracking is not wired through the
// subflow-implemented firing path.
import std/io
import std/field
import std/control

pub event gen { n: usize }
! each usize
| done usize

gen = for(0..n)
! each i |> each(i)
| done => done n

gen(n: 3)
! each i |> std/field:new(bits: 64)
    | field f |> std/io:print.ln("leaking {{ i:d }}")
    | err _ |> _
| done _ |> _
