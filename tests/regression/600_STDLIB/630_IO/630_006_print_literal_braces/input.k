// PINS: a literal `{` or `}` in a print.ln message survives to stdout.
//
// The message reaches Zig's `std.fmt` AS A FORMAT STRING, so an unescaped
// brace used to be read as a placeholder: `print.ln("{\"a\":1}")` died inside
// the stdlib's own bufPrint at comptime, pointing at std/fmt.zig — a location
// the author of the Koru program cannot act on. `{{ … }}` is the
// interpolation opener and is consumed before any byte reaches the literal
// path, so every brace that does arrive IS the author's own text and is
// doubled on the way out (koru_std/io.kz __appendFmtLiteralByte).
//
// Found by the ECS benchmark (tests/benchmarks/003_ecs_reactive): its entries
// must emit one JSON line per run, and no Koru program could print one.
//
// Three shapes in one line, because they fail differently:
//   - a leading `{` followed by an escaped quote (the JSON object opener),
//   - a brace-free run carrying `:` and `,` (no placeholder may be invented),
//   - `{{ n:d }}}` — an interpolation whose closing `}}` is immediately
//     followed by a LITERAL `}`. The scanner must claim the first two and
//     leave the third to the literal path.
import std/io

std/io:print.ln("{\"scenario\":\"dense\",\"sink\":{{ 1720:d }}}")
std/io:print.ln("a { b } c")
