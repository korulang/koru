// PINS: `$mod.` rewrites even immediately after the range operator — the
// splice path AND the module-handler path both walk the same boundary check
// (this file's top-level consumer exercises the splice; the module's own
// handler emission exercises the strip). See lib/ring.kz for the shape.

import std/io
import app/lib/ring

app/lib/ring:push(b: 7)
! saw v |> std/io:print.ln("saw {{ v:d }}")
| count n |> std/io:print.ln("count {{ n:d }}")

app/lib/ring:push(b: 9)
! saw v |> std/io:print.ln("saw {{ v:d }}")
| count n |> std/io:print.ln("count {{ n:d }}")
