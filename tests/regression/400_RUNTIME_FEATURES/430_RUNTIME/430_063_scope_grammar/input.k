// Pins the third render from the register block: scope-grammar teaches HOW a
// call is written (the wire's shape rules, the constant half) above the
// scope's own verb lines (the derived half, scope-vocabulary's render). A
// prompt built from these bytes and a turn judged by parse.wire are one
// declaration read twice — the lesson and the law cannot drift apart.
import std/runtime
import std/io

pub tor open { path: string } -> string<open!>
open -> { "note_0" }

pub tor append { handle: string<!open>, text: string } -> string<open!>
append -> { handle }

pub tor close { handle: string<!open> }
close -> {}

pub tor say { text: string }
say -> {}

std/runtime:register(scope: "notes") {
    open(10)
    append(1)
    close(1)
    say(1)
}

std/runtime:scope-grammar(name: "notes")
| ok g |> std/io:print.ln("{{ g:s }}")
| not-found |> std/io:print.ln("NOT FOUND")

std/runtime:scope-grammar(name: "no-such-scope")
| ok g |> std/io:print.ln("UNEXPECTED: {{ g:s }}")
| not-found |> std/io:print.ln("NOT FOUND")
