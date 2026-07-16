// Obligation stress — explicit discharge composes with auto-discharge.
//
// Intent: releasing `outer` EXPLICITLY (before `inner`, i.e. against the LIFO
// auto-unwind order) leaves only `inner` still holding `<held!>`. Auto-discharge
// must then insert exactly ONE release — `inner` at scope exit — and must NOT
// re-release the already-discharged `outer`. This pins two facts: (a) auto-
// discharge fills in only the still-held obligations, never double-freeing an
// explicitly-released one; and (b) explicit discharge is how you deviate from the
// LIFO default — here the observed order is outer-then-inner, the reverse of what
// auto-discharge alone would produce.
import std/io

pub event lock { name: []const u8 } -> []const u8<held!>
lock -> name

pub event unlock { name: []const u8<!held> }
unlock = std/io:print.ln("unlock {{ name:s }}")

lock(name: "outer"): outer |> lock(name: "inner"): inner |> std/io:print.ln("both held") |> unlock(name: outer)
