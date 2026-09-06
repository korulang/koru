// PIN (RED — codegen): a terminal `=> ok` RE-RAISE of a VOID branch, when the
// step is an inline-transform (print.ln), must still emit the branch return.
//
// `step = print.ln("STEP") => ok` lowers the print as a raw statement and
// DROPS the `return .ok` — the handler falls off the end ("function with
// non-void return type implicitly returns"). The payload-tagged variant works
// (return .{ .ok = v }); the unit variant loses the return in the
// inline-transform path.
//
// Found 2026-09-06, minimized from kopium's d_turns void handle-delta ladder
// (worked around there with multiline bodies that keep a second statement).
import std/io

tor step {}
| ok
| err
step = std/io:print.ln("STEP") => ok

tor probe {}
probe = step()
| ok |> std/io:print.ln("after ok")
| err |> std/io:print.ln("after err")

probe()
