// 690_055 — generalize B-narrow past std/string: a store column holds an
// arbitrary owned pointer `*app/lib/res:Resource<owned!>`. Same lifecycle as the
// owned-String column (690_053): insert CONSUMES <!owned> (move in), take
// REISSUES <owned!> on the row payload (move out), store teardown auto-frees
// each still-live element via the canonical discharger `free`, resolved across
// the module boundary exactly as 690_036 resolves the entity discharger.
//
// Currently RED: store.kz:517 exact-matches only
// `*std/string:String<std/string:instance!>`; any other owned column type is a
// loud later-rung wall. This pin is the generalization target (owned-resource
// columns = the *Player<allocated!> arc); it goes green when the store reads the
// column type + discovers its discharger instead of hardcoding the std/string
// tuple. Uses the bare `<owned!>` spelling (self-resolves to app/lib/res per the
// 2026-07-21 phantom-resolution refinement).
import std/io
import std/store
import app/lib/res

std/store:new(things, capacity: 8) { r: *app/lib/res:Resource<owned!> }

app/lib/res:new(): res |> std/store:insert(things) { r: res }
    | row row |> std/store:take(things[row])
        | item it |> app/lib/res:tag(r: it): t |> std/io:print.ln("tag {{ t:d }}")

app/lib/res:new(): kept |> std/store:insert(things) { r: kept }
    | row _ |> _
