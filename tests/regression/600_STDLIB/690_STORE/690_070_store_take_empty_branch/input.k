// std/store:take gains an `| empty` branch — a take on something that is not a
// live row is a GRACEFUL, handleable outcome, not a panic. `is_panic` (`?!`): a
// site that omits `| empty` still gets the synthesized panic (existing take
// sites unchanged); a site that handles it — an interactive delete off an empty
// list — stays alive. No payload, no obligation on the empty arm.
//
// The re-take is the trigger, and it is an IDENTITY trigger, not a positional
// one. `a` was minted by `| row`; after the first take that handle is stale, so
// `__koru_row_of` finds a generation mismatch, returns null, and the second
// take answers `| empty`. The store's own lowering says this is the intended
// family: never inserted, already taken, or the -1 sentinel.
//
// It was written as `take(items[0])` until 2026-08-02 — a literal integer as a
// row address, which reached `| empty` only by being out of range. That spelling
// died with 690_242 (brands are 1-based, so a bare integer is no longer a
// plausible handle for any store) and it should not come back: position is not
// identity, and `| empty` is about whether a row IS THERE, not about whether an
// offset is in bounds. Note this is why take can be graceful at all while reads
// and writes trap — take is the one verb with a branch surface for absence.
import std/io
import std/store
std/store:new(items, capacity: 4) { v: i64 }
std/store:insert(items) { v: 42 }
| row a |> std/store:take(items[a])
    | item i |> std/io:print.ln("took {{ i.v:d }}")
        |> std/store:take(items[a])
            | item j |> std/io:print.ln("took again {{ j.v:d }}")
            | empty |> std/io:print.ln("empty")
    | empty |> std/io:print.ln("empty")
