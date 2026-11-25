// PIN (collapse-recursion pass, WAY-TWO leg — CONTROL): a recursive tor
// whose else-chain interleaves a foreign call (std/io:print.ln) is not a
// pure accumulator — the structural matchers refuse, so no
// __koru_collapse_ marker may appear. Output stays 3.
import std/io

pub tor bad { n: i64, acc: i64 } -> i64

bad = if(n == 0)
| then -> acc
| else |> bad(n: n - 1, acc: acc + 1): h |> std/io:print.ln("x"): _ |> bad(n: n - 1, acc: h + 1): v -> v

bad(n: 1, acc: 0): r |> std/io:print.ln("{{ r:d }}")
