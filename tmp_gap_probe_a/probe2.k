// PROBE 2 — the actual mission shape: an OWNED, GROWING std/list threaded
// across label-fold (#name/@name) rounds via the consume-in/issue-out pattern.
//
// Grounded per construct:
//   - `#name CALL(...)` fold head, `| branch v |> @name(...)` back-edge,
//     `| branch2 r => other-branch r` escape: tests/regression/200_COMPILER_
//     FEATURES/210_PARSER/210_123_label_on_subflow_rhs_panics/input.kz and
//     tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/
//     330_074_obligation_carried_through_back_edge/input.kz (consume-in/
//     issue-out shape: `step` consumes the carried obligation on input,
//     re-issues exactly one on each output branch).
//   - `if(cond) | then => X | else => Y` pure-Koru conditional:
//     tests/regression/810_AOC_2015/810_201_day20_part1/input.k
//     (`| captured r |> if(r.sum * 10 >= target) | then => found house
//        | else => next { target, house: house + 1, lazy }` — MUST_RUN)
//   - `for(0..n) ! each _ |> std/list:push(nxt, v) | done |> ...`:
//     tests/regression/600_STDLIB/660_COLLECTIONS/660_014_list_push_in_loop/input.k
//   - std/list:new/push/len/free: koru_std/list.kz
//   - nested branch referencing an earlier `| list nxt |>` binding by name:
//     same 660_014/660_007 pattern (`xs` stays in scope across the chain).
//
// Shape: round-fold. Each round CONSUMES the carried list (`cur: <!list>`),
// frees it, builds a FRESH bigger one (grows by one push per round, using the
// round's own running length as the stop condition), and re-issues it
// (`<list!>`) on both the `again` and `done` branches — exactly the
// consume-in/issue-out shape of 330_074, but over std/list's real growable
// *List_i64 instead of a hand-rolled Handle type.
import std/io
import std/list

pub event step { cur: *List_i64<!list> }
| again *List_i64<list!>
| done *List_i64<list!>

step = std/list:free(cur) |> std/list:new(i64)
    | list nxt |> for(0..3)
        ! each _ |> std/list:push(nxt, 1)
        | done |> std/list:len(nxt): n |> if(n < 9)
            | then => again nxt
            | else => done nxt
    | err e |> std/io:print.ln("ERR new {{ e:s }}")

pub event grow-rounds {}
| finished *List_i64<list!>

grow-rounds = std/list:new(i64)
    | list seed |> #r step(cur: seed)
        | again v |> @r(cur: v)
        | done r => finished r
    | err e |> std/io:print.ln("ERR seed {{ e:s }}")

grow-rounds()
| finished xs |> std/list:len(xs): n |> std/io:print.ln("final len={{ n:d }}") |> std/list:free(xs)
