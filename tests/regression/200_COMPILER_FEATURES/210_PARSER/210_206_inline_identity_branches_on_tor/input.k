// Inline identity branches on a tor declaration — the compact single-line
// form. `| ok i64 | bad string` reads on one line like a Result<i64, string>
// and lowers to the same AST as the multiline form; a payloadless inline
// branch (`| missing`) is the same single-line spelling.
import std/io

tor add-one { n: i64 } | ok i64 | bad string

add-one => ok n + 1

// Second inline declaration, mixing identity and payloadless branches
// (compiles even though never called — parse coverage for both forms).
tor probe { id: i64 } | ok i64 | missing

probe => ok id * 2

add-one(n: 4)
| ok v |> std/io:print.ln("got {{ v:d }}")
| bad b |> std/io:print.ln("bad {{ b:s }}")
