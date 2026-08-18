// PINS: a bare-return record type may span lines. `-> {` on the decl line
// with fields on the following lines is the same type as the one-line
// spelling 020_024 / 020_027 pin. A trailing comma after the last field is
// still that record — `string` must lower to `[]const u8`, which the
// unparseable-shape fallback does not do. A `.k` file synthesizes `~` per
// top-level construct; an unclosed return type is still THAT construct, not
// a new tor named after the first field.

import std/io

pub tor run { x: i64 } -> {
    total: i64,
    label: string,
}
run -> { total: x * 2, label: "x" }

run(x: 21): r |> std/io:print.ln("{{ r.total:d }}{{ r.label:s }}")
