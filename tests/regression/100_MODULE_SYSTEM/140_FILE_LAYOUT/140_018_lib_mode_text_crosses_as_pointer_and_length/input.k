// PINS: how TEXT crosses the C boundary under `koruc lib`.
//
// A Koru `string` is a slice — a pointer AND a length — and C has no single
// value for that. So one Koru parameter becomes TWO C parameters:
//
//     pub tor greet { name: string }
//     export fn greet(name_ptr: [*]const u8, name_len: usize) void
//
// The alternatives were rejected for reasons worth keeping: a bare
// `[*:0]const u8` would demand a NUL terminator Koru never promises, and a
// struct-by-value would be an ABI of our own invention that no caller could
// write a header for by hand. Pointer-and-length is what C already does.
//
// A RETURN of text has no equivalent answer — one return slot cannot carry two
// values — so it is refused BY NAME rather than handed an out-parameter
// convention nobody agreed to. Refusing loudly is the point: a caller who
// cannot find a symbol reads why instead of guessing.
//
// This runs as a PROGRAM here, pinning that both shapes still work normally.
// The C half is exercised outside the suite: the emitted library builds as a
// dylib, `nm` shows `_greet` and `_add`, and hand-written C passes a string in
// and gets 42 back.
import std/io

pub tor greet { name: string }
greet = std/io:print.ln("hello {{ name:s }}")

pub tor add { a: i64, b: i64 } -> i64
add -> a + b

greet(name: "Lars")
add(a: 20, b: 22): sum |> std/io:print.ln("add is {{ sum:d }}")
