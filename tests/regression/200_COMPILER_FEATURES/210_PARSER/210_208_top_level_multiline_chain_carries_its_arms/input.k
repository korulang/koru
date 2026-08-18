// PINS: a top-level chain broken across lines carries its arms, exactly as a
// subflow definition already does.
//
// The machinery is not missing. It is written, it runs, and it compiles the
// compiler — a subflow definition with an indented chain and a dedented arm is
// `koru_std/compiler.kz`'s `analysis`, and 210_152 pins the same shape green.
// Only the top-level path never reaches it.
//
// Measured on the identical four lines: as `run = stage-a` / `  |> stage-b` /
// `| failed f => failed f` it runs. Move it to a top-level statement, change
// nothing else, and it is `KORU010: stray continuation line`. The discriminator
// is the POSITION, not the indentation and not the bind.
//
// Here the chain is flat — `seed(): n` and `|> pick(n)` are both at column 0 —
// so the arms at column 0 attach to `pick`, the last step at their level. The
// one-line spelling of this same program is the control: it runs and prints the
// same thing, and formatting is not semantics.
//
// 210_174 is the wall on the other side: arms at a level whose step declares no
// branches. Together they say where an arm may sit and where it may not.
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
