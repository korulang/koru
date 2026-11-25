// PIN (recursion-unroll pass, challenge 035 leg — CONTROL): tak is
// excluded under the v1 predicate. Its 4 self-call sites permute which
// caller param decreases into which callee position, and the dependent
// `tak(t1,t2,t3)` site has NO affine-decreasing argument at all — no
// common measure exists, and s=4 would explode G(D) anyway. The pass must
// refuse: the emitted shape stays the flat segment machine —
// `__koru_seg_eval` present, exactly 1 `tak_event.handler(` site (the
// external call), no substituted guards.
import std/io

pub tor tak { x: i64, y: i64, z: i64 } -> i64

tak = if(x > y)
| then |> tak(x: x - 1, y, z): t1 |> tak(x: y - 1, y: z, z: x): t2 |> tak(x: z - 1, y: x, z: y): t3 |> tak(x: t1, y: t2, z: t3): v -> v
| else -> z

tak(x: 3, y: 2, z: 1): r |> std/io:print.ln("{{ r:d }}")
