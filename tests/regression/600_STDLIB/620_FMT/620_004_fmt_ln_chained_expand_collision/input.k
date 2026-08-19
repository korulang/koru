// TEST: TWO chained std/fmt:ln hops — the [expand] result constant must be
// unique per splice, not a fixed name.
//
// Sibling facet of 620_003 (same root defect: [expand] splice result names
// from a fixed pool collide when a later splice adds another hop at the
// same depth). The fix names each expand result after the path it walks;
// 620_003 covers the origin case, this covers the chain case. Both were
// originally written with `| line r` — the bare-return branch form the
// shape checker now refuses — and bind `: r` instead.

import app/net
import std/fmt
import std/io

app/net:connect(host: "localhost")
| ok c |> std/fmt:ln("GET /conn/{{ c:d }}"): req
    |> std/fmt:ln("wrapped: {{ req.text:s }}"): req2
        |> app/net:write(conn: c, data: req2.text)
            | ok w |> app/net:read(conn: w)
                | ok r |> app/net:shutdown(r.conn)
                    | ok |> _
                    | err _ |> _
                | err _ |> _
            | err _ |> _
| err _ |> _