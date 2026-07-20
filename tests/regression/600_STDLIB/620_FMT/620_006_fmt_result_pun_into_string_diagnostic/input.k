// RULING 3: punning a whole std/fmt RESULT STRUCT into a scalar/string param
// must be a koru diagnostic, never a raw Zig type leak.
//
// `std/fmt:ln(...): text` binds a RESULT STRUCT (`{ text: []const u8 }`), not a
// string. `sink()` leaves its `text: string` param unfilled, so the inline
// scalar-bind pun would fill `text: text` — emitting invalid Zig
// (`.text = text` where `text` is a struct: `expected '[]const u8', found
// '...__struct...'`). That raw Zig error must NOT reach the user. Instead we
// emit KORU038 with a source line that guides to the field access `text.text`
// (every passing fmt test consumes the result via `.text`, e.g. 620_002's
// `l.text` — never the bare bind).
import std/fmt
import std/io

event sink { text: string }
sink = std/io:print.ln(text)

std/fmt:ln("value: 7"): text |> sink()
