// 690_059 — EXPLICIT field-projection discharge on a SINGLE-field store row.
// A store row is a synthesized aggregate (record), NOT a user-authored type, so
// "no single-item records" doesn't govern it: even a one-owned-column row is a
// record `{ r }`, and `it.r` field-projection discharge works. Here `take` yields
// `| item it` (it.r holds <owned!>) and the caller EXPLICITLY discharges it via
// `free(it.r)` (not auto-discharge). Proves the field-narrowing / record-field
// discharge machinery applies to single-field store rows — the substrate the
// drain rung's `! discharge item |> …(item.field)` relies on.
import std/io
import std/store
import app/lib/res

std/store:new(things, capacity: 8) { r: *app/lib/res:Resource<owned!> }

app/lib/res:new(): res |> std/store:insert(things) { r: res }
    | row row |> std/store:take(things[row])
        | item it |> app/lib/res:free(it.r) |> std/io:print.ln("explicitly freed")
