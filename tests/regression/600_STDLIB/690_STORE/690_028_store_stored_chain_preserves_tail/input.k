// A `stored` write is an ordinary void step: whatever is chained after it
// with `|>` must still run. This pins the CHAIN form (`stored |> stored`),
// the sibling of 690_009's multi-field envelope BLOCK form. The two writes
// target distinct fields of one singleton; the watch reports each, so both
// lines prove the tail survived the first write's transform.
//
// (Non-`stored` void chains — `print |> print` — already chain correctly
// everywhere, top-level and in spliced watch/interceptor bodies; this pins
// that `stored` joins them rather than swallowing its continuation.)

import std/io
import std/store

std/store:new(a) { x: 0[i64], y: 0[i64] }

std/store:watch(a)
! x v |> std/io:print.ln("x {{ v:d }}")
! y v |> std/io:print.ln("y {{ v:d }}")

std/store:stored { a.x: 1 } |> std/store:stored { a.y: 2 }
