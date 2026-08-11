// Pins: a NAMED LABEL with a binding on a bare-return call binds that call's
// result at a SUBFLOW head, the same as it already does at a flow head
// (210_195) and nested inside another continuation (320_121).
//
// A bare-return tor produces one untagged value, so a label there is binding
// sugar for `: r` — there is no tag to switch on. A subflow head only ever
// lowered the `: r` spelling; the label spelling fell through to a switch on a
// value carrying no tags, which is not expressible in Zig at all, so the
// failure arrived as raw backend text about an enum literal and an i64.
//
// Three shapes, one rule: a plain subflow implementation, and the same thing
// reached through an abstract tor's implementation.
import std/io

tor double { value: i64 } -> i64
double -> value * 2

tor plain { n: i64 } -> i64
plain = double(value: n)
    | doubled d -> d

[abstract] tor viaAbstract { n: i64 } -> i64

input:viaAbstract = double(value: n)
    | doubled d -> d + 1

plain(n: 21): a |> std/io:print.ln("{{ a:d }}")
viaAbstract(n: 10): b |> std/io:print.ln("{{ b:d }}")
