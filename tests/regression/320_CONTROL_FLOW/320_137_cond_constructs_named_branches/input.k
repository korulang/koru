// Pins: cond arms construct named event branches with `=>` (same glyph as
// `if | then => more` in 020_028 / 240). Value-produce `cond` + `->` is
// 320_133; this pin is the branch-constructor twin for app routers
// (page-route → | catalog | progress | …).
import std/io

tor page-route { page: i64 }
| catalog
| progress
| other

page-route = cond(page)
| c p when p == 0 => catalog
| c p when p == 1 => progress
| c _ => other

page-route(page: 0)
| catalog |> std/io:print.ln("catalog")
| progress |> std/io:print.ln("progress")
| other |> std/io:print.ln("other")

page-route(page: 1)
| catalog |> std/io:print.ln("catalog")
| progress |> std/io:print.ln("progress")
| other |> std/io:print.ln("other")

page-route(page: 9)
| catalog |> std/io:print.ln("catalog")
| progress |> std/io:print.ln("progress")
| other |> std/io:print.ln("other")
