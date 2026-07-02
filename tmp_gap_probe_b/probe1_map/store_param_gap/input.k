// Minimal repro for the day07/day22 ledger's named blocker: can an OWNED
// std/string-map handle be passed as a parameter to a USER-defined event?
// Grounded on the exact repro named in
// tests/regression/810_AOC_2015/810_221_day22_part1/input.k:
//   "any user event `pub event f { xs: *List_i64<!list> }` with a `new`-ed
//    list passed in -> KORU030 at the call"
import std/io
import std/string-map

pub event lookup { m: *Map_string_i64<map>, k: []const u8 }
| value i64
| missing

lookup = std/string-map:get(m, k)
| value v => value v
| missing => missing

std/string-map:new()
| map m |> std/string-map:set(m, k: "a", v: 1) |> lookup(m, k: "a")
    | value v |> std/io:print.ln("{{ v:d }}") |> std/string-map:free(m)
    | missing |> std/io:print.ln("MISSING") |> std/string-map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
