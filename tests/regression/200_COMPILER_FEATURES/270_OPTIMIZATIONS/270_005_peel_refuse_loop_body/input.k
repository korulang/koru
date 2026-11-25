// PIN (recursion-unroll pass, challenge 035 leg): effects-bearing recursion
// must REFUSE — silently, unchanged. The body is the eligible fib shape plus
// a `for` loop carrying a console effect inside the recursive branch (the
// 320_184 shape: a `for` is legal inside a tor body). Two independent
// refusal grounds: the `for` is a continuation node kind outside the pass's
// allowed set {if-dispatch, self-call, expression/return leaves}, and the
// loop body bears a std/io effect that unrolling would duplicate. Baseline:
// 3 `fibloop_event.handler(` sites, no substituted guards. expected.txt
// records the deterministic per-internal-node "x" lines plus the result.
// (Substituted for a capture-mutation pin: `captured {}` cannot appear in a
// tor impl body — `! as` cannot head an impl flow, KORU040.)
import std/io

pub tor fibloop { n: i64 } -> i64

fibloop = if(n < 2)
| then -> n
| else |> fibloop(n: n - 1): a
    |> for(0..1)
        ! each _ |> std/io:print.ln("x")
        | done |> fibloop(n: n - 2): b -> a + b

fibloop(n: 5): r |> std/io:print.ln("{{ r:d }}")
