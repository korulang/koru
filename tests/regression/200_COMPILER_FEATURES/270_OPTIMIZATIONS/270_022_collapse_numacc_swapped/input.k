// PIN (collapse-recursion, C3 leg — CONTROL): same custody shape but the
// self-call assigns the SUM to a and the dup half to b — (a,b) -> (a+b, b),
// a different recurrence. The C3 matcher requires a <- dup-half, b <- sum,
// so it must refuse: no __koru_collapse_ marker. Output stays 3e0 (the
// honest slow path: (0,1) -> (1,1) -> (2,1) -> (3,1)).
import std/io
import std/num

pub tor swp { n: i64, a: string<!std/num:exact>, b: string<!std/num:exact> } -> string<std/num:exact!>

swp = if(n <= 0)
| then |> std/num:free(n: b) -> a
| else |> std/num:dup(n: b): d |> std/num:add(a, d.b): s |> swp(n: n - 1, a: s, b: d.a): r -> r

std/num:from-int(i: 0): a0 |> std/num:from-int(i: 1): b0 |> swp(n: 3, a: a0, b: b0): f
|> std/io:print.ln("{{ f:s }}") |> std/num:free(n: f)
