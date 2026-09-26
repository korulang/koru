// PINS: the store name mints `__KoruStoreT_<name>` in the emitted program —
// `evil(x)` reads the call tail into the name and produces
// `const __KoruStoreT_evil(x) = struct` — Zig dies inside generated code on
// a symbol the author never wrote. A store name is a single identifier.
import std/io
import std/store

std/store:new(evil(x), capacity: 4) { v: i64 }
std/store:new(ok_name, capacity: 4) { v: i64 }
std/store:insert(ok_name) { v: 1 }
std/io:print.ln("rows: {{ ok_name.len:d }}")
