// 400_172 — `|` (continuation marker) on an EFFECT branch is a kind error.
// `query` installs a standing rule and fires the effect arm `! query`; it mints
// no matchable outcome event. Writing `| query` is the inverse marker/kind
// mismatch to 400_171 — `!` and `|` are separate kinds, and the marker must
// match the branch's declared kind. koru rejects it in the query transform,
// where the standing-rule branch vocabulary is validated.
import std/io
import std/store
std/store:new(game, capacity: 8) { hp: i64 }
std/store:query(game)
| query { entity.hp } |> std/io:print.ln("hp {{ hp:d }}")
std/store:insert(game) { hp: 5 }
