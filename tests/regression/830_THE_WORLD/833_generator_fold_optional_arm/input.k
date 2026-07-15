// The World in Koru — generators. Pins the follow-up frontier left by the
// flow-body effect-inlining fix (832 green): folding a flow generator that
// ALSO declares an OPTIONAL effect arm.
//
// 832 made a pure-Koru flow generator's `! each` stream foldable with `capture`
// by giving flow-bodied events the same in-flow-scope inline splice procs get.
// But an event with an optional effect arm (`! ?tap`) keeps the LEGACY path:
// optional arms lower presence to `@hasDecl(__H, "tap")`, which needs the `__H`
// comptime param the inline splice deliberately has no. So this event bails to
// the standalone-Handlers-struct-fn path, where the mutable accumulator can't
// cross the fn boundary — the same shape 832 pinned before its fix.
//
// What closing this needs: presence resolved from the caller's continuations
// (`ctx.inline_fire_conts`, codegen-time knowledge of what was installed)
// instead of a comptime `__H` lookup — so an optional-arm flow event can take
// the inline splice too. Presence itself is intact (400_145/147/154 green);
// this guards only the inline-fold × optional-arm intersection.
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
