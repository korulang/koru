// A continuation HANDLER produces the enclosing event's bare return with `->`.
//
// `classify` is a bare-return event (`-> i64`). Its body dispatches on `check`'s
// two continuation branches, and EACH arm satisfies classify's bare return by
// producing an expression with `->`:  `| big b -> b * 100`.  The `|` selects the
// arm and binds; the `->` returns the value (the produce glyph). This is legal
// in a HANDLER (it satisfies the signature) — distinct from a branch DECL, where
// `->` is illegal (see the reject test), and from `=>`, which constructs a named
// branch.
//
// PINNED (2026-06-29): no corpus coverage for handler-produced bare returns yet.
import std/io

tor check { n: i64 }
| big i64
| small i64

check = if(n > 10)
| then => big n
| else => small n

tor classify { n: i64 } -> i64
classify = check(n)
| big b -> b * 100
| small s -> s

classify(n: 21): r |> std/io:print.ln("{{ r:d }}")
