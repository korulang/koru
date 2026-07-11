// PIN (2026-07-03): tail-self-continuation loop-lowering corrupts cross-referencing
// recursive-call arguments. When a tail self-call re-enters (the "recursion that was a
// loop" flattening), the emitter reassigns the arguments SEQUENTIALLY without staging
// them into temporaries — so an argument whose new value reads another argument that
// was ALREADY reassigned sees the updated value instead of the old one. A parallel-
// assignment must stage all RHS first.
//
// Euclid's gcd is the canonical victim: gcd(a: b, b: @mod(a, b)) — `a` is reassigned to
// `b`, then `b`'s RHS `@mod(a, b)` reads the NEW `a`, computing @mod(b, b) = 0, so the
// next iteration hits the base case and returns the first `b`. The emitted Zig shows the
// smoking gun literally: `a = b;  b = a;`.
//
// gcd(48, 18) = 6 (48=2^4·3, 18=2·3^2 -> gcd 6). The bug yields 18.
// Single-argument or non-tail recursion (fact/sumto) is unaffected — only the tail->loop
// path with mutually-referential args. Surfaced by the koru-benchmarks `gcdsum` kernel.
import std/io

pub event gcd { a: i64, b: i64 }
| value i64

gcd = if(b == 0)
| then => value a
| else |> gcd(a: b, b: @mod(a, b))
    | value v => value v

gcd(a: 48, b: 18)
| value g |> std/io:print.ln("{{ g:d }}")
