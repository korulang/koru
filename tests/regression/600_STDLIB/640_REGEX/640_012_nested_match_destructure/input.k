// Regression: a regex match nested inside another match's branch. Both
// destructures used a fixed `__koru_dst` temp, so the inner shadowed the outer
// ("local constant __koru_dst shadows ...") — Zig rejected it. The transform
// already site-uniquified __koru_match_in / __koru_sp; the emitter's destructure
// temp was the straggler. Now location-suffixed. Surfaced by AoC day16
// (`Sue N: rest` → per-piece `prop: val`).
import std/io
import std/regex

std/regex:match("a1b2")
| `(?<x>[a-z])(?<rest>.+)` { x: string, rest: string } |> std/regex:match(rest)
    | `(?<y>[0-9])(?<tail>.+)` { y: i64, tail: string } |> std/io:print.ln("{{ x:s }} {{ y:d }} {{ tail:s }}")
    | no-match |> std/io:print.ln("inner-no")
| no-match |> std/io:print.ln("outer-no")
