// RED PIN (2026-07-18): a MULTI-FIELD stored block through the query-row
// cursor dies with "unknown store '<s>[__koru_qrow]'" — the stored
// transform mis-parses the indexed lvalue head when the block writes more
// than one field. Single-field is green (690_008); chained single-field
// writes are the legal form meanwhile (chain-envelope ruling: one atomic
// unit). Surfaced by koru-libs raylib bounce.k's movement rule.
import std/io
import std/store

std/store:new(game) { a: i64, b: i64 }

std/store:insert(game) { a: 1, b: 10 }
| row _ |> _
| full |> _

std/store:query(game)
! query { entity.a, entity.b } |> std/store:stored { entity.a: entity.a + 1, entity.b: entity.b + 1 }

std/store:query(game)
! query { entity.a, entity.b } |> std/io:print.ln("a {{ a:d }} b {{ b:d }}")
