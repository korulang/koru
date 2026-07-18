// Pins named-field record PRODUCE. `-> { skip: "...", trivia: "..." }` must
// lower to a Zig struct literal `.{ .skip = ..., .trivia = ... }`, mapping to
// the declared return shape. The capture path already emits records correctly;
// the produce/return path must route through that same lowering instead of
// dumping the record expression raw (which emits invalid Zig `return { ... }`).
// This is also the `! config -> { skip, trivia }` grammar-config shape.
import std/io

pub event config { strict: bool } -> { skip: string, trivia: string }

config = if(strict)
    | then -> { skip: "WS", trivia: "CMT" }
    | else -> { skip: "NONE", trivia: "NONE" }

config(strict: true)
| got { skip, trivia } |> std/io:print.ln("skip={{ skip:s }} trivia={{ trivia:s }}")
