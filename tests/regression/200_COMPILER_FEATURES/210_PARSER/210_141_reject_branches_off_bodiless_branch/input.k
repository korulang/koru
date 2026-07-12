// Pins the arm-from-nothing wall (KORU105, ruled 2026-07-12): a terminal `|`
// branch with no body cannot carry nested branches — branches hang off a
// thing that PICKS (an invocation dispatching, an effect resuming), and a
// bodiless arm picks nothing. The parser nests continuations purely by
// indentation, so without this wall the shape parses and drifts through the
// passes ungoverned; std/parser's first sequencing spelling comptimed over
// exactly this tolerated-but-unruled AST before the ruling killed it.
// Effect `!` arms keep their one aligned level of resume arms (400_133;
// decl flatness is 210_134's pin).
import std/regex
import std/io

std/regex:match("x")
| `[a-z]+` _
    | `[0-9]+` n |> std/io:print.ln("{{ n:s }}")
| no-match |> std/io:print.ln("no")
