// PINS: a value bound by a chain step REACHES a `stored` write block's rhs.
//
// Measured 2026-07-31: 138 `std/store:stored` sites in the corpus and zero of
// them take a value from a chain binding — every rhs is column reads and
// literals. A sweep arm demonstrably chains and binds (690_098 binds `t` off
// `std/string:read` and prints it); this is the same bind carried one step
// further, into the write block. `t` names `e.a`'s value, `e.b: t` lands it.
//
// The composition is what makes written-order (690_126) a mechanism instead of
// a wart: upstream work happens in the chain, the block only writes. 690_131
// is the shape a user reaches for on top of this rung.
//
// `echo` is 230_014's identity tor — declared `-> i64`, implemented as the
// bare-return subflow `echo -> v` — so the bind is a real chain-step result,
// not a projection the block could have read for itself.
import std/io
import std/store

tor echo { v: i64 } -> i64
echo -> v

std/store:new(cells, capacity: 2) { a: i64, b: i64 }

std/store:insert(cells) { a: 3, b: 7 }

std/store:query(cells)
! query e |> echo(v: e.a): t |> std/store:stored { e.b: t }

std/store:query(cells)
! query r |> std/io:print.ln("a {{ r.a:d }} b {{ r.b:d }}")
