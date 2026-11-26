// PIN (collapse-recursion, C3 leg): a num-custody linear recurrence
//   T { n:i64, a:string<!std/num:exact>, b:string<!std/num:exact> } -> string<std/num:exact!>
// whose else-chain is dup(b) -> add(a, d.f1) -> T(n-1, a: d.f2, b: s)
// collapses to a single parse + O(n) Dec limb-adds + single format:
// marker __koru_collapse_c3_numacc. fib(10) -> 5.5e1 proves semantics;
// fib(0) -> 0e0 proves the free-then-return base arm (no parse on base).
import std/io
import std/num

pub tor fibn { n: i64, a: string<!std/num:exact>, b: string<!std/num:exact> } -> string<std/num:exact!>

fibn = if(n <= 0)
| then |> std/num:free(n: b) -> a
| else |> std/num:dup(n: b): d |> std/num:add(a, d.b): s |> fibn(n: n - 1, d.a, b: s): r -> r

std/num:from-int(i: 0): a0 |> std/num:from-int(i: 1): b0 |> fibn(n: 10, a: a0, b: b0): f
|> std/io:print.ln("{{ f:s }}") |> std/num:free(n: f)
std/num:from-int(i: 0): a1 |> std/num:from-int(i: 1): b1 |> fibn(n: 0, a: a1, b: b1): g
|> std/io:print.ln("{{ g:s }}") |> std/num:free(n: g)
