// PIN (collapse-recursion pass, WAY-TWO leg): pow-mod's multiplicative
// accumulator (acc*base mod P, e decreasing) admits R2b square-and-multiply —
// O(log e) instead of O(e). The kebab-case event name must mangle to
// pow_mod_event in the residual spelling (writeMangledSeg parity) — an
// unmangled `pow-mod_event` parses as subtraction and fails the backend.
// 3^10 mod 1e9+7 = 59049 proves semantics.
import std/io

pub tor pow-mod { base: i64, e: i64, acc: i64 } -> i64

pow-mod = if(e == 0)
| then -> acc
| else |> pow-mod(base, e: e - 1, acc: @rem(acc * base, 1000000007)): v -> v

pow-mod(base: 3, e: 10, acc: 1): r |> std/io:print.ln("{{ r:d }}")
