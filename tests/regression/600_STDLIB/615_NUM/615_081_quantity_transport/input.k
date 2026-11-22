import std/io
import std/num
import std/quantity

// <*> on runtime-text inputs: a produced (allocated!) value must reach
// string params the same as literal text. num:render is the producer.
// Expression/Source params are the other half of the rule — call-site
// text only; runtime text goes ingest/parse — and stay unqualified.

// produced decimal text -> unit-dim: "1.5e0" is not a unit — the
// honest arm is bad-unit, but the transport must deliver it
std/num:lit(s: "1.5")
  | exact a |> std/num:render(n: a): r
      |> std/quantity:unit-dim(s: r)
          | ok d |> std/io:print.ln("ud-ok") |> std/io:free(content: r)
          | bad-unit |> std/io:print.ln("ud-bad-unit") |> std/io:free(content: r)
  | bad _ |> std/io:print.ln("bad-lit")

// produced text -> ext-canon: not ext-shaped — honest bad
std/num:lit(s: "1.5")
  | exact a |> std/num:render(n: a): r
      |> std/quantity:ext-canon(s: r)
          | ok e |> std/io:print.ln("ec-ok") |> std/io:free(content: r) |> std/io:free(content: e)
          | bad |> std/io:print.ln("ec-bad") |> std/io:free(content: r)
  | bad _ |> std/io:print.ln("bad-lit")

// chain: ext-canon produced text feeds ext-canon again — the ok path
std/quantity:ext-canon(s: "USD^1")
  | ok e1 |> std/quantity:ext-canon(s: e1)
      | ok e2 |> std/io:print.ln("{{ e2:s }}") |> std/io:free(content: e2) |> std/io:free(content: e1)
      | bad |> std/io:print.ln("chain-bad") |> std/io:free(content: e1)
  | bad |> std/io:print.ln("bad-canon")
