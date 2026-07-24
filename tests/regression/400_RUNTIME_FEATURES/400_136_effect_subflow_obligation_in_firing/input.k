// SUBFLOW-IMPLEMENTED EFFECTS, obligations, balanced case (pure .k, no proc)
// — the subflow sibling of 400_100, and the actual prize of the arc: with the
// generator implemented as a Koru subflow, the per-firing obligation rule is
// PROVED by the phantom checker end-to-end instead of the firing being trusted
// to an opaque proc. The obligation source is std/field (new issues <field!>,
// free discharges <!field>) so no host code appears anywhere.
//
// The consumer's `! each` handler creates AND discharges within the same
// firing. `! each` carries no resume, so nothing may escape — here it
// doesn't, and the program must run.
import std/io
import std/field
import std/control

pub tor gen { n: usize }
! each usize
| done usize

gen = for(0..n)
! each i |> each(i)
| done => done n

gen(n: 3)
! each i |> std/field:new(bits: 64)
    | field f |> std/io:print.ln("firing {{ i:d }}") |> std/field:free(f)
    | err _ |> _
| done _ |> _
