// The World in Koru — generators. Pins: a NAMED generator event's stream,
// folded consumer-side into a running sum with `capture` — the Python
// `sum(gen)` idiom, and the shape a compute-bound generator benchmark needs.
//
// Terminal is void `| done` (a pure yielding generator hands back no summary;
// echoing `n` out is meaningless). Yielding + void-done + a printer consumer
// composes (831), and the same fold over the ANONYMOUS `for(0..n) ! each i`
// composes — so what this guards is folding a *named, reusable* generator
// consumer-side, where the mutable `capture` accumulator must thread into the
// consumer's lowered handler. The failure mode it pins is that leaking as raw
// generated Zig instead of a Koru diagnostic:
//
//   output_emitted.zig: error: mutable 'acc' not accessible from here
//                       (crosses namespace boundary / const Handlers_0 = struct)
//
// Design note: that threading should lower through a Koru subflow, not a
// template.
import std/io

pub tor nats { n: usize }
! each usize
| done

nats = for(0..n)
! each i |> each(i)
| done => done

capture { sum: 0[usize] }
! as acc |> nats(n: 10)
    ! each i |> captured { sum: acc.sum + i }
  | done |> _
| captured result |> std/io:print.ln("{{ result.sum:d }}")
