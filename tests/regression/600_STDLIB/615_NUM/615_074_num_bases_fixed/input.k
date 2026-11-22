// std/num gate: prefixed base spellings (0x/0b/0o) admit on lit and
// parse alike — one grammar on both lanes — and render-fixed expands
// canonical Ne±M to place-value text for display, refusing |too-large
// past the 64KiB bound (a taint-derived exponent is a memory-amplifier).
import std/io
import std/num

std/num:lit(s: "0xFF")
| exact a |> std/num:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "0b101")
| exact a |> std/num:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "0o17")
| exact a |> std/num:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "-0x10")
| exact a |> std/num:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "0xGG")
| exact a |> std/num:render(n: a): t |> std/io:print.ln("BUG") |> std/io:free(content: t)
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "0b102")
| exact a |> std/num:render(n: a): t |> std/io:print.ln("BUG") |> std/io:free(content: t)
| bad b |> std/io:print.ln("bad")

std/num:ingest(s: "0x2A"): i0 |> std/num:parse(s: i0)
| exact a |> std/num:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad m |> std/io:print.ln("pbad") |> std/io:free(content: m)

std/num:lit(s: "1e-3")
| exact a |> std/num:render-fixed(n: a)
    | exact t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | too-large |> std/io:print.ln("tl")
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "5.5e0")
| exact a |> std/num:render-fixed(n: a)
    | exact t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | too-large |> std/io:print.ln("tl")
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "1.23e2")
| exact a |> std/num:render-fixed(n: a)
    | exact t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | too-large |> std/io:print.ln("tl")
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "-4.5e-2")
| exact a |> std/num:render-fixed(n: a)
    | exact t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | too-large |> std/io:print.ln("tl")
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "1e70000")
| exact a |> std/num:render-fixed(n: a)
    | exact t |> std/io:print.ln("BUG") |> std/io:free(content: t)
    | too-large |> std/io:print.ln("too-large")
| bad b |> std/io:print.ln("bad")

std/num:lit(s: "0e0")
| exact a |> std/num:render-fixed(n: a)
    | exact t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | too-large |> std/io:print.ln("tl")
| bad b |> std/io:print.ln("bad")
