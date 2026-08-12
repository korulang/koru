// Pins: a standalone .k full program may declare PRIVATE (non-pub) events.
// A .k is a full program, not a contract-only surface — the private event is
// implemented as pure Koru in-file and a local flow calls it. Guards the
// removal of KORU111 Rule 1 ("private event in contract file").
import std/io

tor add-one { value: i32 } -> i32

add-one -> value + 1

add-one(value: 10): a |> std/io:print.ln("{{a:d}}")
