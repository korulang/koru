// PINS the wall of 510_119 one level deeper: a branch constructor nested in
// a flow arm must name the declared payload's fields, not only a declared
// branch. `| then => ok { c: 3, d: 4 }` names a real branch with two fields
// the payload does not declare — the branch-name wall passes it, and the
// field disagreement reached Zig as `no field named 'c'` against
// output_emitted.zig.
import std/io

pub tor pick { x: i64 }
| ok { a: i64, b: i64 }
| bad i64

pick = if(x > 0)
| then => ok { c: 3, d: 4 }
| else => bad 0

pick(x: 1)
| ok o |> std/io:print.ln("{{ o.a:d }}{{ o.b:d }}")
| bad _ |> _
