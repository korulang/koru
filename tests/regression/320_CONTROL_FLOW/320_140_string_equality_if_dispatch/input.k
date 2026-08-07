// Pins: `==` and `!=` on runtime strings in an `if` condition, on BOTH
// targets. Koru's `==` on strings is VALUE equality — the comptime fold
// (comptime_eval.zig), the interpreter, and the JS target already agreed;
// this pins the Zig emission (`@import("std").mem.eql`) into the same
// meaning. The shape is 320_128's if-produce with a string param — the
// command-dispatch idiom (route a runtime word, not a numeric code).
import std/io

pub tor route { cmd: string } -> string

route = if(cmd == "start")
| then -> "starting"
| else -> "unknown"

pub tor gate { word: string } -> i64

gate = if(word != "secret" and word != "admin")
| then -> 0
| else -> 1

route(cmd: "start"): r |> std/io:print.ln(r)
route(cmd: "stop"): r2 |> std/io:print.ln(r2)
gate(word: "guest"): a |> std/io:print.ln("{{ a:d }}")
gate(word: "secret"): b |> std/io:print.ln("{{ b:d }}")
