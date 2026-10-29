// PINS: a record-payload branch constructor names each declared payload
// field, no others. `| ok { a: i64, b: i64 }` declares two fields;
// `=> ok { c: 3, d: 4 }` constructs two the declaration does not have. The
// name set is a membership test over the branch's declared fields — the same
// facts checkImplMatchesDecl already reads for the branch NAME — but the
// field set was never compared, so the disagreement reached Zig as
// `no field named 'c'` against output_emitted.zig.
//
// The declared law is already on the books: payload fields may not carry
// defaults because "every constructor supplies the field explicitly", and
// the destructure side checks names against the payload as KORU036
// (210_147). This pin is the construct-side twin of 510_114: a name the
// declaration does not carry cannot be produced, whether the name is a
// branch or one of its fields.
import std/io

pub tor pick { x: i64 }
| ok { a: i64, b: i64 }
| bad i64

pick => ok { c: 3, d: 4 }

pick(x: 1)
| ok o |> std/io:print.ln("{{ o.a:d }}{{ o.b:d }}")
| bad _ |> _
