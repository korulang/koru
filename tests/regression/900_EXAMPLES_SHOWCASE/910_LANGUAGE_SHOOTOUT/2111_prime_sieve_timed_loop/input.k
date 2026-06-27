// GREEN (2026-06-28): the PURE-KORU drag-race harness shape. A `#L`/`@L`
// label-fold loop whose `| live` arm runs a FULL allocating sieve pass
// (std/field:new -> for/`! each` with the compiler-GENERATED mark-multiples
// transform -> std/field:free) and THEN tail-recurses via `@L` with an
// incremented payload count. The loop body, the pass count, and the recursion
// are all Koru — exactly the structure that lets Koru time its own benchmark
// without a Zig loop.
//
// 320_097 pinned the EMIT PATH for a label-fold with a value-producing head and
// a nested `~if` step, but its `| live` arm was trivial (`@L(l.limit, l.passes)`).
// THIS pins the next thing: a `| live` arm carrying a multi-step ALLOCATING flow
// (heap field alloc, a `for` loop firing an `! each` effect per i, a `[transform]`
// that emits a specialized strided marker, and a `free`) that must fully discharge
// before the `@L` back-edge fires. That is the emit shape the real timed entry uses;
// the only difference is the clock — here a deterministic counter (`if(passes < limit)`)
// so the pass count is stable, in the real entry `std/time:now()`.
//
// The validation sieve after the loop confirms the marker is correct: 78,498
// primes <= 1,000,000 (odds-only storage, 500,000 bits).
import std/io
import std/field
import std/control

pub event tick { limit: i64, passes: i64 }
| live { limit: i64, passes: i64 }
| expired i64

pub event run { limit: i64 }
| total i64

tick = if(passes < limit)
| then => live { limit, passes }
| else => expired passes

run = #L tick(limit, passes: 0)
| live l |> std/field:new(bits: 500000)
    | field f |> for(1..500)
        ! each i |> std/field:test(f, i): pv |> if(pv == 0)
            | then |> std/field:mark-multiples(f, 2 * i * (i + 1), 2 * i + 1, 499999)
        | done |> std/field:free(f) |> @L(l.limit, passes: l.passes + 1)
    | err _ |> _
| expired e => total e

run(limit: 5)
| total n |> std/field:new(bits: 500000)
    | field g |> for(1..500)
        ! each i |> std/field:test(g, i): pv |> if(pv == 0)
            | then |> std/field:mark-multiples(g, 2 * i * (i + 1), 2 * i + 1, 499999)
        | done |> std/field:count-zeros(g, 1, 500000): c |> std/io:print.ln("passes: {{ n:d }}") |> std/io:print.ln("validated primes: {{ c + 1:d }}") |> std/field:free(g)
    | err _ |> _
