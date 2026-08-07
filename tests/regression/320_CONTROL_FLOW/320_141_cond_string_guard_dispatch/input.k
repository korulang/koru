// Pins: `cond` arms guarded by string equality against literals, on BOTH
// targets — the app-router shape of 320_137 with the scrutinee a STRING,
// not a numeric code. Before string `==` reached the Zig target, exactly
// this router had to stamp numeric codes into its markup to dispatch.
import std/io

tor page-route { page: string }
| catalog
| progress
| other

page-route = cond(page)
| c p when p == "catalog" => catalog
| c p when p == "progress" => progress
| c _ => other

page-route(page: "catalog")
| catalog |> std/io:print.ln("catalog")
| progress |> std/io:print.ln("progress")
| other |> std/io:print.ln("other")

page-route(page: "progress")
| catalog |> std/io:print.ln("catalog")
| progress |> std/io:print.ln("progress")
| other |> std/io:print.ln("other")

page-route(page: "missing")
| catalog |> std/io:print.ln("catalog")
| progress |> std/io:print.ln("progress")
| other |> std/io:print.ln("other")
