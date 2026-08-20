// Pins the contract half of the void story: a tor with NO implementation is a
// legal declaration. The program compiles and the scope's vocabulary renders —
// a bodyless tor is a promise on the wire, not an error. Koru refuses it only
// at the moment of INVOCATION, never at declaration. (The explicit no-op, the
// implemented half, is pinned by 430_058/430_063/430_064 delegating to
// std/void:placeholder.)
//
// The four verbs below have no bodies at all. Under register their events are
// declared, and scope-vocabulary renders the same surface a full scope would.
// Nothing calls them. The phase where a stub fails to compile is the phase
// where it is actually invoked — that is the difference this pin freezes.
import std/runtime
import std/io

pub tor open { path: string } -> string<open!>
pub tor append { handle: string<!open>, text: string } -> string<open!>
pub tor close { handle: string<!open> }
pub tor say { text: string }

std/runtime:register(scope: "notes") {
    open(10)
    append(1)
    close(1)
    say(1)
}

std/runtime:scope-vocabulary(name: "notes")
| ok vocab |> std/io:print.ln("{{ vocab:s }}")
| not-found |> std/io:print.ln("NOT FOUND")