// PINS the handle-validity wall FOR THE FIRST STORE IN THE PROGRAM — the one
// case where it was off.
//
// A handle packs `slot | (brand << 24)`, and `__koru_resolve` refuses any
// address whose top byte is not the addressed store's brand. That refusal is
// what 690_115 and 690_196 pin. The brand was the store's declaration ordinal,
// which started at ZERO — so for whichever store came first, the check
// `(slot32 >> 24) != 0` was false for every small integer and the wall let
// plain data through as an address.
//
// Measured 2026-08-02, this exact program: `alpha` accepted the integer 0,
// wrote 999 into row 0 and printed happily, while the SAME construction on
// `beta` — identical in every way except being declared second — trapped
// correctly. Position in the source decided whether a safety wall existed.
//
// Brands are now 1-based, which also reserves 0 so that a DENSE row index and
// a HANDLE are disjoint as values: a dense cursor leaked into a handle
// position fails loudly instead of addressing some unrelated slot.
//
// `alpha` is declared FIRST on purpose. Moving it below `beta` would make this
// test pass for the wrong reason and it would never say so.
import std/io
import std/store

std/store:new(alpha, capacity: 4) { val: i64, ref: i64 }
std/store:new(beta, capacity: 4) { val: i64, ref: i64 }

// `ref` holds a plain 0 — a number, never a handle either store issued.
std/store:insert(alpha) { val: 111, ref: 0 }
| row a |> std/io:print.ln("seeded 111")
    |> std/store:stored { alpha[a.ref].val: 999 }
        |> std/io:print.ln("UNREACHABLE: brand 0 let a non-handle address a row")
