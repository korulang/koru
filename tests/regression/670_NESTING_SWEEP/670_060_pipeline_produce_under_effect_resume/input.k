// NESTING SWEEP — a `|>` pipe-chain feeding a bare-return `->` produce,
// nested UNDER an effect-RESUME arm (position: effect-resume, a context the
// 5-construct/6-position grid doesn't cover — a `! ask` handler's own body,
// not `! each`/`! line`/`! v`'s per-fire handler feeding a `| done` terminal).
//
// Grounds: (a) the produce glyph inside an effect arm — `! ask _ -> "Alice"`
// (210_079_effect_branch_resume_expression:12); (b) a `|>` chain whose LAST
// hop binds and produces with `->` — `a(x): r1 |> b(x: r1): r2 -> r2`
// (020_030_chained_subflow_bind_produce:18); (c) the subflow-implemented
// effect shape itself, `query = ask(q): a => done a` /
// `query(q: 41) ! ask v -> v + 1 | done r |> ...`
// (400_132_effect_subflow_plain_resume_bind:14,20).
//
// Here the effect-resume arm's body is a full chain — `! ask v |>
// bump(x: v): w -> w + 1` — rather than (b)'s bare atomic expression, betting
// that the resume-produce codepath threads a mid-chain bind the same way the
// ordinary event bare-return codepath does. query(q: 41): ask fires with
// v = 41; bump(x: 41) -> 42, bound as w; the arm produces w + 1 = 43 as the
// resume value; `a` resumes at 43; `=> done a` constructs done(43).
import std/io

pub event query { q: i64 }
! ask i64 -> i64
| done i64

query = ask(q): a => done a

pub event bump { x: i64 } -> i64
bump -> x + 1

query(q: 41)
! ask v |> bump(x: v): w -> w + 1
| done r |> std/io:print.ln("{{ r:d }}")
