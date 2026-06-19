// AoC 2015 Day 10 Part 1 — look-and-say. Statement example: "1" after 5
// rounds → 312211 (the real puzzle runs 40 rounds on a personal input —
// same machinery, bigger n). The ROUND LOOP is Koru (5 rounds, state held
// across iterations); each round reads the current sequence run-by-run and
// builds the next.
//
// Ledger — BLOCKED on a real obligation-system gap (the per-round scan is
// fine; carrying the GROWING SEQUENCE across rounds is not yet expressible):
//
//   Look-and-say rebuilds the sequence every round: round N reads the old
//   sequence and produces a brand-new, longer one that round N+1 then reads.
//   So an OWNED, growing buffer (a *List_i64<list!> of digits, or a
//   *String<instance>) must be THREADED from one round to the next. Koru has
//   exactly two cross-iteration state mechanisms and neither carries an owned
//   resource today:
//
//     1. Label-fold branch payloads (#round/@round, the day-4/day-20 idiom).
//        Threading a *List_i64<list!> through a continue-branch payload trips
//        KORU030: "Resource 'nxt' with phantom state <list!> was not
//        discharged. No event accepts <!list>." The auto-discharge pass reads
//        the branch-payload EXIT as a leak instead of a handoff to the
//        recursive @round re-invocation (whose param consumes <!list>). When
//        the fold result is then handed to a further event, the same gap
//        surfaces as the terser "Unknown event referenced" at emit time.
//        (Minimal repro: a #r/@r fold over `step { cur: *List_i64<!list> } |
//        again { nxt: *List_i64<list!> } | done *List_i64<list!>` — KORU030,
//        even when the threaded list is freed downstream.)
//
//     2. Capture-cell accumulators (`! as a` / `captured {...}`, the day-8
//        idiom). These reliably thread SCALARS only; a cell field typed as a
//        *List_i64 handle compiles but does not thread the live handle through
//        iterations (the body silently produces no effect).
//
//   A single outer list mutated in place across a `for` loop works fine —
//   what is missing is replacing/handing-off an OWNED buffer per round, i.e.
//   ownership transfer of a phantom-obligation resource through fold payloads.
//   This is the same gap that holds day 22 (810_221) RED with the identical
//   error. It is design-shaped (obligation threading through label folds),
//   not a missing leaf — left RED honestly pending that work.
//
// GAP: obligation-system — no ownership transfer of a phantom-obligation
//      resource (*List_i64<list!>, *String<instance>) across loop/fold
//      iterations. KORU030 on label-fold branch payloads; capture cells thread
//      scalars only.

import std/io
import std/fs

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_101_day10_part1/input.txt")
! line _ |> _
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
