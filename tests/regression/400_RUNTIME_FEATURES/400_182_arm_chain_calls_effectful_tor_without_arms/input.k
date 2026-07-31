// PINS: an arm-nested chain calling an effect-carrying tor with no arms
// installed — the omitted optional param fills with null AND the empty
// Handlers type is passed. See lib/pulse.kz for the shape and provenance.

import std/io
import app/lib/pulse

tor drive {}
drive = app/lib/pulse:gate()
| yes |> app/lib/pulse:pulse(n: 4)
    | done v |> std/io:print.ln("v {{ v:d }}")
| no |> _

drive()
