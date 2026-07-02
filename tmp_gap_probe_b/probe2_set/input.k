// PROBE 2: std/set distinct count — insert 5 strings-as-values with 2 duplicates,
// expect count 3. std/set is i64-keyed only (koru_std/set.kz header: "First cut:
// i64 keys"), so strings are hashed to i64 at the call site for this probe.
// Grounded on tests/regression/600_STDLIB/660_COLLECTIONS/660_018_set_dedup_count/input.k
import std/io
import std/set

std/set:new()
| set s |> std/set:add(s, 1) |> std/set:add(s, 2) |> std/set:add(s, 2) |> std/set:add(s, 3) |> std/set:add(s, 1) |> std/set:count(s): n |> std/io:print.ln("{{ n:d }}") |> std/set:free(s)
| err e |> std/io:print.ln("ERR {{ e:s }}")
