// Single-entry records collapse to the scalar everywhere `->` PRODUCES a value:
// legal is `-> i64` or `-> { a, b, ... }`, never `-> { a }`. This pins the rule
// in the BARE-RETURN produce position — the sibling of 210_063's branch-payload
// rejection. A one-field record return must be guided to the scalar `-> i64`;
// the multi-field record return (241/242) is the legal form. The single-field
// event INPUT payload (`{ strict: bool }`) is exempt and stays legal.
import std/io
pub event config { strict: bool } -> { a: i64 }
config = if(strict)
    | then -> { a: 1 }
    | else -> { a: 0 }
config(strict: true): r |> std/io:print.ln("{{ r.a:d }}")
