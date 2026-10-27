// PINS: the REFUSAL of an `std/indexes` declaration naming a store that is
// never declared. The declaration is AST-data discovered by the named
// store's `new` emit — a name nothing claims goes silently dead: no field,
// no machinery, no diagnostic, and the author believes `ghost` is indexed.
// Same dead-claim family as the second-declaration wall (690_328) and the
// column-less wall (690_329) — refused at the declaration's own location.
import std/store
import std/indexes
import std/io

std/store:new(players, capacity: 8) { key: i64 }
std/indexes:ordered(ghost, key)

std/store:insert(players) { key: 1 }
|> std/io:print.ln("unreachable")
