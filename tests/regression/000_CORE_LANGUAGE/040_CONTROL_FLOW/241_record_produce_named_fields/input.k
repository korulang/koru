// Pins named-field record PRODUCE + inline-produce (`: bind`) CONSUMPTION.
// `-> { a: i64, b: i64 }` lowers to a Zig struct literal, and the caller reads
// it back with `config(...): r |> ... r.a`. Guards the classification that
// routes `-> {record}` through the shared struct-literal path (parser.zig) for
// every emitter, and the `: bind` consumption of a bare-return record.
import std/io
pub tor config { strict: bool } -> { a: i64, b: i64 }
config = if(strict)
    | then -> { a: 1, b: 2 }
    | else -> { a: 0, b: 0 }
config(strict: true): r |> std/io:print.ln("a={{ r.a:d }} b={{ r.b:d }}")
