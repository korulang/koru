// Test (ASPIRATIONAL, MUST_RUN, currently failing): phantom literal-suffix
// at call site participates in the full phantom system end-to-end.
//
// Parallels 330_063 (celsius/fahrenheit conversion via subflow) but
// originates the celsius value with a LITERAL-SUFFIX instead of via an
// event:
//
//   330_063:  ~read-temp = reading 22.5
//             ~read-temp(...) | reading c |> to-fahrenheit(c: c)
//
//   330_066:  ~to-fahrenheit(c: 22.5<celsius>)
//             // The literal `22.5` originates with phantom <celsius>;
//             // no event needed for the origination.
//
// Validates the full pipeline:
//   - Parser accepts `22.5<celsius>` at arg-value position
//   - Phantom checker matches literal's `<celsius>` against the param's
//     declared `f32<celsius>`
//   - Emitter strips the `<celsius>` suffix, emits bare `22.5` to Zig
//   - Conversion runs, prints fahrenheit result
//
// Currently fails — parser doesn't yet implement literal-suffix annotation
// extraction. When fixed, this should print `72.5 F` (= 22.5 * 9/5 + 32).
//
// See `docs/UNITS_OF_MEASURE.md` for the full design. Implementation work
// needed: parser extension for literal-suffix in arg-value position
// (Implementation sketch item 6).

import std/io

tor to-fahrenheit { c: f32<celsius> } -> f32<fahrenheit>

to-fahrenheit -> c * 9.0 / 5.0 + 32.0

to-fahrenheit(c: 22.5<celsius>): f |> std/io:print.ln("{{ f:f }} F")
