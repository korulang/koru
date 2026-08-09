// PINS: the omitted twin of 400_177 — the consumer installs NO `! note`
// arm, so the spliced `@hasDecl(__H, "note")` probe must rewrite to a
// literal `false`: the drip runs silent, no note fires, no `__H` reaches
// Zig. An unheard optional void arm is a comptime-folded no-op at the fire
// site (the 400_145 ruling), and the proc's own presence probe must agree
// with it.

import std/io
import app/lib/streamer

app/lib/streamer:drip(n: 3)
| done t |> std/io:print.ln("done {{ t:d }}")
