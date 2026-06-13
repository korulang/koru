// RED PIN — flow-scope mutable list (growable). PROPOSED, unbuilt.
//
// GROUNDED: void ops chain with bare `|>` (810_071: `print.ln(...) |> query(...)`);
// void events are declared with ZERO `|` branches (io.kz eprintln/success/warn).
// `new` mirrors from-int's owned constructor shape `| ok | err`.
//
// PROPOSED (shoot at this):
//   std/list:new(i64) | list xs | err e   — owned constructor, freed at flow exit
//   std/list:push(xs, V)                  — VOID mutation; growable push panics on
//                                           OOM (the approved split), chains with `|>`
//   xs.len                                — read-access in expression position
// OPEN: should growable `new` surface OOM (`| err`, as here) or be infallible
//       (panic, single `| list`)? Same surface-vs-panic call as push.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, 3) |> std/list:push(xs, 4) |> std/io:print.ln("{{ xs.len:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
