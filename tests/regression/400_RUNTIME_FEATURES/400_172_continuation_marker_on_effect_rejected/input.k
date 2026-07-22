// 400_172 — `|` (continuation marker) on an EFFECT branch MUST be rejected.
// `query` INSTALLS a standing rule and fires the EFFECT arm `! query`. Writing
// `| query` (the continuation/outcome marker) is the inverse marker/kind
// mismatch to 400_171. Today koru silently accepts it (compiles + runs `hp 5`).
// RED until koru rejects `|` on an effect at its own boundary. `!` and `|` are
// separate kinds; the marker must match the event's declared branch-kind.
import std/io
import std/store
std/store:new(game, capacity: 8) { hp: i64 }
std/store:query(game)
| query { entity.hp } |> std/io:print.ln("hp {{ hp:d }}")
std/store:insert(game) { hp: 5 }
