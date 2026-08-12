// PINS: arms sit at the level of the step they attach to, and a step that
// declares no branches cannot take any.
//
// An arm attaches to the LAST STEP AT ITS OWN INDENTATION LEVEL. Here the only
// step at column 0 is `seed(): n` — and `seed` is declared `-> i64` with no
// branches at all, so `| lo` and `| hi` have nothing to attach to. They are
// reaching past the indented `pick(n)`, which is the step that actually
// declares them.
//
// This is a type fact before it is a layout one. A step either names its value
// or branches on it, never both: `seed(): n` has already caught what `seed`
// produced. Indenting the arms to `pick`'s level does not rescue it either —
// measured, it drops both branches instead of one.
//
// The legal spelling de-dents the chain so `pick` is the last step at column 0,
// where the arms already are — pinned green at 210_190.
//
// The rule generalises rather than being special to this shape. In
// `koru_std/compiler.kz`, `analysis`'s dedented `| failed` attaches to
// `check-release-gate` at the same level, and `check-release-gate` DOES declare
// `| failed`; the desugar then replicates it across every stage. "The choke
// guards the subtree" describes that replication, not the attachment.
//
// The diagnostic below is the one emitted today and it is inadequate: it names
// a line the parser could not place rather than the fault. What it should say
// is that these arms are at the level of a step declaring no branches, and name
// the step that declares them. The code is pinned so the message can improve
// without breaking this wall.
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
