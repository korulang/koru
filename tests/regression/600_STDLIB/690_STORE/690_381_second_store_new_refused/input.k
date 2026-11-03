// PINS: the REFUSAL of a second `std/store:new` on a name the same module
// already declared. The name mints `__KoruStoreT_<name>` / `__koru_store_<name>`
// at one emitted scope — a second `new` re-mints the same Zig symbols and the
// program dies in the backend on "duplicate struct member" errors the author
// never wrote. The LATER declaration is the offender (the same ruling the
// second-index-decl wall carries, 690_328), so the refusal points at its line.
import std/store
import std/io

std/store:new(players, capacity: 8) { key: i64 }
std/store:new(players, capacity: 8) { key: i64, other: i64 }

std/store:insert(players) { key: 1, other: 2 }
|> std/io:print.ln("unreachable")
