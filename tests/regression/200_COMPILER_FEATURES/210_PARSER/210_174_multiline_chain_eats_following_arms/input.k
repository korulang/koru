// PINS: breaking a pipeline across lines does not change what it means.
//
// A branching invocation in mid-chain takes its arms perfectly well when the
// chain is written on ONE line. Put a newline before the `|>` and the arms
// that follow become "stray continuation line without Koru construct" — the
// multi-line chain swallows them.
//
//     seed(): n |> pick(n)     <- arms attach
//     seed(): n
//         |> pick(n)           <- arms are stray
//
// Same tors, same arms, same order. Only the line break moves.
//
// Formatting is not semantics. A long pipeline is exactly where an author
// reaches for line breaks, so this bites the programs most in need of them —
// and the diagnostic accuses the arms, which are innocent, rather than the
// chain that ate them.
import std/io

tor seed {} -> i64
proc seed|zig { return 7; }

tor pick { n: i64 }
| lo i64
| hi i64
proc pick|zig {
    if (n < 10) return .{ .lo = n };
    return .{ .hi = n };
}

seed(): n
    |> pick(n)
| lo a |> std/io:print.ln("lo {{ a:d }}")
| hi b |> std/io:print.ln("hi {{ b:d }}")
