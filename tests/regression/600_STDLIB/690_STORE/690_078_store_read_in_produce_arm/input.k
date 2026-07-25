// A store cell read from a PRODUCE arm — `peek -> s.v`, the bare-return form.
//
// Cell reads are rewritten `s.v` -> `__koru_store_s.v` across the program, and
// the walk that does it visits flows. A bare-return subflow is not a flow: it
// lands as an `immediate_impl` carrying the produced expression, so a read
// there used to travel to the host untouched and Zig rejected an undeclared
// `s`. Valid Koru, host-level error — the wall was not built at this position.
//
// Nothing here crosses a module: the same read inside a chained step has always
// worked, so what this pins is the POSITION, not the reach (110_022 pins the
// reach). Both guards are needed — they fail independently.
import std/io
import std/store

std/store:new(s) { v: 7[i64] }

pub tor peek {} -> i64
peek -> s.v

pub tor doubled {} -> i64
doubled -> s.v * 2

peek(): a |> std/io:print.ln("peek={{ a:d }}")
doubled(): b |> std/io:print.ln("doubled={{ b:d }}")
