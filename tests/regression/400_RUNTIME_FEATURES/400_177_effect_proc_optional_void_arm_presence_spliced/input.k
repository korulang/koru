// PINS: `@hasDecl(__H, "<arm>")` in a zig proc body survives the top-level
// inline splice — rewritten to `true` here, because this consumer INSTALLS
// the optional `! note` arm. The twin (400_178) omits it and pins `false`.

import std/io
import app/lib/streamer

app/lib/streamer:drip(n: 3)
! note i |> std/io:print.ln("note {{ i:d }}")
| done t |> std/io:print.ln("done {{ t:d }}")
