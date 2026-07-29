// Pins that a koru.json `paths` key is matched as the LONGEST covering module
// path, on segment boundaries — not as the first path segment.
//
// `koru` and `koru/vaxis` both cover `koru/vaxis`; the specific key wins, so the
// import lands on the vendored tree. `koru/other` has no key of its own and
// still resolves through the shorter `koru`, which is what makes this a widening
// rather than a replacement: redirecting one module leaves its neighbours alone.

import std/io
import koru/vaxis
import koru/other

koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
koru/other:greet(): o |> std/io:print.ln("{{ o:s }}")
