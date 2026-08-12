// SUBFLOW-IMPLEMENTED EFFECTS, the generator (pure .k, no proc) — the subflow
// sibling of 400_100's `gen` and the .k realization of 400_115's intent. The
// impl drives `for(0..n)` (std/control, the same `! each`/`| done` consumer
// shape as 2111) and satisfies gen's arms from for's arms using ONLY the
// established subflow forms:
//   - `! each i |> each(i)` — for's firing chains into a CALL of gen's own
//     `each` arm. Firing-is-a-call, exactly what a `proc` body does with
//     `each(i)` (400_100); the chain step is stock grammar (220_021).
//   - `| done => done n` — for's terminal maps to gen's terminal with the
//     established `=>` branch mapping (240 `| continue => iterated`).
// No new glyphs; the novelty is only WHO may call an arm (the declaring
// event's own impl) — which is what lifts effect firing to flow-level checking.
import std/io
import std/control

pub tor gen { n: usize }
! each usize
| done usize

gen = for(0..n)
! each i |> each(i)
| done => done n

gen(n: 3)
! each i |> std/io:print.ln("{{ i:d }}")
| done _ |> _
