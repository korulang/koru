// Test: std/runtime:scope-manifest serves a scope's vocabulary as a JSON data
// contract — the register block minted as a data structure at scope creation,
// not a hand-written doc. Same bytes as enforcement: the possession arcs and
// argument types rendered here are the ones the interpreter checks before
// dispatch, from the same EventEntry records the dispatch tables are emitted
// from. Feeds the Orisha .json endpoint and the `explain` host downstream.
//
// Pure-surface form (.k): the tilde does not exist here — a pure-Koru file
// rejects it outright (PARSE003), which is exactly the point of the spelling.
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

std/runtime:scope-manifest(name: "notes")
| ok json |> std/io:print.ln("{{ json:s }}")
| not-found |> std/io:print.ln("NOT FOUND")

std/runtime:scope-manifest(name: "no-such-scope")
| ok json |> std/io:print.ln("UNEXPECTED: {{ json:s }}")
| not-found |> std/io:print.ln("NOT FOUND")