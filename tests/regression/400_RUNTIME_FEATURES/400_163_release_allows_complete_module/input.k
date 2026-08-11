// The other half of the gate: a complete, non-prototype module builds fine
// under `--release`. The release gate rejects ONLY `[prototype]` modules — it
// must never touch ordinary code. Every terminal branch is handled here and
// there is no `[prototype]` annotation, so `--release` compiles and runs it.

import std/io

pub tor run {}
| done string
| err string

run => done "release build, all branches handled"

run()
| done msg |> std/io:print.ln(msg)
| err msg |> std/io:print.ln(msg)
