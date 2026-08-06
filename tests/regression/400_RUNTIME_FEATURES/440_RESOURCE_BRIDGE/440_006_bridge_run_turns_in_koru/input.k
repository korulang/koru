// TEST: the whole conversation, in a pure .k entry — no Zig reach-in.
//
// Turn 1 opens a file and walks away from it. Turn 2, a SEPARATE run, closes the
// file turn 1 opened. Then the session hangs up. This is the resource bridge's
// entire first use case: resources retained across calls.
//
// `440_004` does the same thing and has to drop into Zig for `&br.pool`, because
// until `std/bridge:run` existed the mechanism was real and the Koru surface over
// it was not. This file is pure plumbing — the events and their procs live in
// `session.kz`, which also registers the scope.
//
// `[with]std/bridge:create` opens the bridge's vocabulary for the rest of the
// flow, so `run` and `close` are bare. The opening is UNRESOLVED-ONLY: a name the
// entry already owns is never shadowed (641_011).
//
// EVERY arm hangs up, including the failures, and that is not tidiness — it is
// forced. `create` mints `<session!>`; an arm that reports a failed turn and
// walks away leaves the session undischarged and the program does not compile
// (KORU030, "Call: close"). A turn can fail eight ways, so a two-turn
// conversation carries sixteen hang-ups. That cost is the guarantee, seen from
// the inside.

import std/bridge
import std/io
import app/session

[with]std/bridge:create(id: "session-1", scope: "files"): br |> run(br, source: "open(path: \"a.txt\")")
| result r1 |> run(br, source: "close-file(handle: \"file_1\")")
    | result r2 |> close(br): still |> std/io:print.ln("turn 1: {{ r1.handles:d }} held, turn 2: {{ r2.handles:d }} held, hung up still: {{ still:d }}")
    | exhausted _ |> close(br): _ |> std/io:print.ln("FAIL: turn 2 exhausted")
    | parse-error _ |> close(br): _ |> std/io:print.ln("FAIL: turn 2 parse error")
    | validation-error _ |> close(br): _ |> std/io:print.ln("FAIL: turn 2 validation error")
    | shape-error _ |> close(br): _ |> std/io:print.ln("FAIL: turn 2 shape error")
    | event-denied _ |> close(br): _ |> std/io:print.ln("FAIL: turn 2 event denied")
    | dispatch-error e2 |> close(br): _ |> std/io:print.ln("FAIL: turn 2 {{ e2.message:s }}")
    | scope-not-found _ |> close(br): _ |> std/io:print.ln("FAIL: turn 2 scope not found")
| exhausted _ |> close(br): _ |> std/io:print.ln("FAIL: turn 1 exhausted")
| parse-error _ |> close(br): _ |> std/io:print.ln("FAIL: turn 1 parse error")
| validation-error _ |> close(br): _ |> std/io:print.ln("FAIL: turn 1 validation error")
| shape-error _ |> close(br): _ |> std/io:print.ln("FAIL: turn 1 shape error")
| event-denied _ |> close(br): _ |> std/io:print.ln("FAIL: turn 1 event denied")
| dispatch-error e1 |> close(br): _ |> std/io:print.ln("FAIL: turn 1 {{ e1.message:s }}")
| scope-not-found _ |> close(br): _ |> std/io:print.ln("FAIL: turn 1 scope not found")
