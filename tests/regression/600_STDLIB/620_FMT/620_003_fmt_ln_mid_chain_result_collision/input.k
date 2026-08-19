// TEST: std/fmt:ln spliced MID-CHAIN between branch-outcome handler calls.
//
// Pins the emitter result_N collision: the flow emitter names handler
// results result_<counter>, and the transform/inline-expansion splice
// (std/fmt:ln's inline_body) misaligned the counter so an inner handler
// result collapsed onto an outer one:
//
//   error: local constant 'result_1' shadows local constant from outer scope
//
// Shape mirrors openssl/examples/02_interp_write.kz (the live repro) but
// with a dependency-free sibling module: connect -> fmt:ln -> write ->
// read -> shutdown, each returning | ok / | err outcomes so the emitter
// nests switches. Without the fmt:ln hop the same chain numbers uniquely.

import app/net
import std/fmt
import std/io

app/net:connect(host: "localhost")
| ok c |> std/fmt:ln("GET /conn/{{ c:d }}"): req
    |> app/net:write(conn: c, data: req.text)
        | ok w |> app/net:read(conn: w)
            | ok r |> app/net:shutdown(r.conn)
                | ok |> _
                | err _ |> _
            | err _ |> _
        | err _ |> _
| err _ |> _