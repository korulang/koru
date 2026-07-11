// SUBFLOW-IMPLEMENTED EFFECTS, obligations, no-escape negative (pure .k, no
// proc) — the subflow sibling of 400_103, the discriminator. `! each` carries
// no <state!> resume, so an obligation born in the consumer's handler CANNOT
// escape the firing. Here the handler creates a <field!> obligation
// (std/field:new) and never frees it — unbalanced, and it must be rejected
// with KORU030 even though the generator is a pure-Koru subflow. If this is
// silently accepted, obligation tracking is not wired through the
// subflow-implemented firing path.
//
// COMPILER_FLAGS: --auto-discharge=disable (the 2104_21 precedent). With
// default flags this program is LEGAL: std/field:free is the unambiguous
// discharge for <field!>, so the auto-discharge inserter settles the
// obligation per-firing (the free lands INSIDE the handler body — the
// per-firing rule holding by insertion, identically for proc-backed and
// subflow-backed generators). The enforcement path this test pins only
// exists with insertion off; without the flag the pin would contradict
// the auto-discharge feature itself.
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
