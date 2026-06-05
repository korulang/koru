// Pure-`.k` `if` with `print.ln` branch bodies fails to compile on the JS
// target (RED on js-compile; the zig target compiles + runs fine). This is the
// construct the playground default and self-contained `.k` programs reach for
// (Lars's repro). `print(text: ...)` branches are fine — it's print.ln (a
// comptime transform) as an if-branch body, on the JS path, that breaks.
// Pins a real JS-emission bug; a target divergence like this must be closed
// (or the JS path must error cleanly), never silently crash.
import std/io

if(7 > 3)
| then |> std/io:print.ln("big")
| else |> std/io:print.ln("small")
