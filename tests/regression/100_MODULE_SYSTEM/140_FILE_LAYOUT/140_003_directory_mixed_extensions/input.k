// Phase 2: a directory module containing both `.kz` and `.kjs` siblings.
// Directory enumeration should pick up files of every Koru extension and
// register both as submodules under the directory's namespace.


import std/io
import app/lib

app/lib/alpha:greet-alpha(): a |> std/io:print.ln("{{ a:s }}")

app/lib/beta:greet-beta(): b |> std/io:print.ln("{{ b:s }}")
