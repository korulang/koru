// PRACTICAL container-to-container move inside a loop — the i64 (no-obligation
// element) baseline. Own list A AND list B outside the loop (per 330_015: own
// outside, borrow inside, dispose after). Inside for(0..n): pop an element off A
// (a <list> borrow — A stays alive) and push it into B (also a borrow). i64
// elements carry NO obligation, so this is a plain DATA shuffle, not a phantom
// transfer — it establishes that the container discipline (two owned handles
// borrowed across a loop, both freed after) composes. The element-level
// OBLIGATION transfer is the job of 330_082 / 330_083.
//
// Grammar grounded in: 660_008 (pop branches + free), 660_012/660_014 (push/get
// in a for-loop with free on `| done`), 330_015 (own-outside/borrow-inside).
import std/io
import std/list

std/list:new(i64)
| list a |> std/list:push(a, 10) |> std/list:push(a, 20) |> std/list:push(a, 30) |> std/list:new(i64)
    | list b |> std/list:len(a)
        | len n |> for(0..n)
            ! each _ |> std/list:pop(a)
                | item v |> std/list:push(b, v)
                | empty  |> _
            | done |> std/list:len(b)
                | len m |> std/io:print.ln("moved into b: {{ m:d }}") |> std/list:free(a) |> std/list:free(b)
    | err e |> std/io:print.ln("ERR b {{ e:s }}")
| err e |> std/io:print.ln("ERR a {{ e:s }}")
