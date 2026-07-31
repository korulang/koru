// PINS: an omitted optional parameter inside a tor's IMPL FLOW fills with
// null, the same as at top level. Both calls below omit `scale` — the
// top-level one always worked; the one inside `announce`'s impl flow is the
// pinned path. See lib/maker.kz.

import std/io
import app/lib/maker

tor announce {}
announce = app/lib/maker:make(tag: 4): v |> std/io:print.ln("impl {{ v:d }}")

app/lib/maker:make(tag: 2): w |> std/io:print.ln("top {{ w:d }}")

announce()
