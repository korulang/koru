// The World in Koru — generators. Pins: folding a flow generator that ALSO
// declares an OPTIONAL effect arm (`! ?tap`), consumer-side with `capture`.
//
// 832 made a pure-Koru flow generator's `! each` stream foldable by giving
// flow-bodied events the same in-flow-scope inline splice procs get. This
// extends that to events whose contract includes an optional arm: presence
// resolves from the caller's continuations (`ctx.inline_fire_conts`) instead
// of `@hasDecl(__H, ...)`, so the mutable accumulator stays in-scope. Presence
// itself lives in 400_145/147/154; this guards only the inline-fold ×
// optional-arm intersection.
import std/io

pub event gen { n: usize }
! each usize
! ?tap usize
| done

gen = for(0..n)
! each i |> each(i)
| done => done

capture { sum: 0[usize] }
! as acc |> gen(n: 10)
    ! each i |> captured { sum: acc.sum + i }
  | done |> _
| captured result |> std/io:print.ln("{{ result.sum:d }}")
