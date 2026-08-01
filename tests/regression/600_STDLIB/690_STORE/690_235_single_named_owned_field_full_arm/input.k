// PIN (documented gap, red on purpose): a store whose ONLY column is a
// named owned field loses the phantom through the `| full` rejection
// record — free(s: f.text) reports "no tracked phantom state". Add ANY
// scalar sibling column ({ text: ..., n: i64 }) and the same code tracks
// and compiles; the anonymous single-field form ({ *String<instance!> })
// also tracks. Sibling of 690_233 (cross-module fields drop out of the
// record even WITH siblings).
//
// Found by kopium d_turns' draft store, which went anonymous instead.
// When the tracker learns the one-named-column record, flip to MUST_RUN.

import std/string
import std/store

std/store:new(draft, capacity: 2) { text: *std/string:String<instance!> }

tor seed {}
seed = std/string:from-page(text: "")
| ok a |> std/string:take(s: a): m |> std/store:insert(draft) { text: m }
    | row _ |> _
    | full f |> std/string:free(s: f.text)
| err _ |> _

seed()
