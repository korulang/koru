// PROBE 1 — literal minimal repro named in the 810_221_day22_part1 ledger:
//   "any user event `pub event f { xs: *List_i64<!list> }` with a `new`-ed
//    list passed in -> KORU030 at the call" (tests/regression/810_AOC_2015/
//    810_221_day22_part1/input.k, ledger comment block)
//
// Grounded per construct:
//   - `pub event NAME { params } -> T` + `NAME -> expr` bare-return impl:
//     tests/regression/000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_023_subflow_arrow_return/input.k
//   - named-arg call site `NAME(param: value): binding`: same 020_023 test
//     (`double(a: 21): d`)
//   - `std/list:new(i64)` generic constructor + `| list xs |>` / `| err e |>`
//     branches: koru_std/list.kz + tests/regression/600_STDLIB/660_COLLECTIONS/
//     660_007_list_new_transform/input.k
//   - `*List_i64<!list>` phantom spelling: koru_std/list.kz header comment
//     ("<!list> - consumed: free discharges the obligation") and the ledger's
//     own quoted minimal repro.
import std/io
import std/list

pub event f { xs: *List_i64<!list> } -> i64
f -> 1

std/list:new(i64)
| list xs |> f(xs): r |> std/io:print.ln("{{ r:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
