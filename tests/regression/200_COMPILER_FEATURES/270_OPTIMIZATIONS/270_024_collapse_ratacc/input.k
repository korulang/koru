// PIN (collapse-recursion, C3 kit-table leg): the numacc family admits a
// second custody kit — the `std.rational:rational` phantom selects
// koru_rational's kit contract (kitParse/kitFromInt/kitMul/kitAdd/kitNeg/
// kitDeinit/kitEmit/kitFree), so a rational-custody recurrence collapses to
// parse-once + O(log n) limb fast-doubling + emit-once: marker
// __koru_collapse_c3_ratacc. fibr(10) -> rat:v1;55;1 proves the bare-add
// path; pellr(12) -> rat:v1;13860;1 proves the from-int+mul coefficient
// path (x_{i+1} = 2*x_i + x_{i-1}); fibr(0) -> rat:v1;0;1 proves the
// free-then-return base arm (no parse on base).
import std/io
import std/rational

pub tor fibr { n: i64, a: string<!std/rational:rational>, b: string<!std/rational:rational> } -> string<std/rational:rational!>

fibr = if(n <= 0)
| then |> std/rational:free(n: b) -> a
| else |> std/rational:dup(n: b): d |> std/rational:add(a, d.b): s |> fibr(n: n - 1, d.a, b: s): r -> r

pub tor pellr { n: i64, a: string<!std/rational:rational>, b: string<!std/rational:rational> } -> string<std/rational:rational!>

pellr = if(n <= 0)
| then |> std/rational:free(n: b) -> a
| else |> std/rational:dup(n: b): d |> std/rational:from-int(i: 2): two |> std/rational:mul(d.b, a: two): pb |> std/rational:add(a: pb, b: a): s |> pellr(n: n - 1, d.a, b: s): r -> r

std/rational:from-int(i: 0): a0 |> std/rational:from-int(i: 1): b0 |> fibr(n: 10, a: a0, b: b0): f
|> std/io:print.ln("{{ f:s }}") |> std/rational:free(n: f)
std/rational:from-int(i: 0): a1 |> std/rational:from-int(i: 1): b1 |> pellr(n: 12, a: a1, b: b1): g
|> std/io:print.ln("{{ g:s }}") |> std/rational:free(n: g)
std/rational:from-int(i: 0): a2 |> std/rational:from-int(i: 1): b2 |> fibr(n: 0, a: a2, b: b2): h
|> std/io:print.ln("{{ h:s }}") |> std/rational:free(n: h)
