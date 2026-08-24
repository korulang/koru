// Proto-derived container: std/list:new over a declared proto synthesizes the
// six op events (new/push/len/get/pop/free) with heap-allocated input field
// arrays. 660_028 guards the synthesis contract that 660_005 cannot see: every
// slot of a synthesized op's input fields must be ASSIGNED before splice —
// push-<Name> allocates 2 slots and once left in[0] undefined, so the
// compiler's own Phase-2.6 rescan read field.@"type" as 0xaaaa poison and
// segfaulted (branch proto/list-vertical-slice, found 2026-08-24). The scalar
// pins never touch this path: it fires only for a proto element.
import std/io
import std/types
import std/list

std/types:proto(Engine) {
    rpm: i32
    serial: string
}

std/list:new(Engine)
| list xs |> std/list:push(xs, v: 10) |> std/list:push(xs, v: 20) |> std/list:len(xs): n |> std/io:print.ln("len={{ n:d }}") |> std/list:pop(xs)
    | item v |> std/io:print.ln("popped {{ v:d }}") |> std/list:free(xs)
    | empty  |> std/io:print.ln("EMPTY") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
