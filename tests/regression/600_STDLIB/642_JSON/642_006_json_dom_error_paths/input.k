// std/json:dom error and edge paths — `malformed` carries the Scanner's
// error name; `at` on a missing key is `not-found`; `at`/`idx` on the
// wrong node kind is `wrong-kind`; `idx` past the end is
// `out-of-bounds`; `val` dispatches every scalar kind (int, float,
// bool, null, numstr for numbers too wide for i64/f64).
import std/io
import std/json

// malformed input — unterminated object
std/json:dom.parse(input: "{\"a\":")
| malformed m |> std/io:print.ln("BAD {{ m:s }}")
| ok doc |> std/json:dom.free(doc)

std/json:dom.parse(input: "[1,2.5,true,null,\"s\"]")
| malformed m |> std/io:print.ln("BAD2 {{ m:s }}")
| ok doc |> std/json:dom.root(doc): r
    |> std/json:dom.at(n: r, key: "nope")
        | found _ |> _
        | not-found |> std/io:print.ln("at-on-array wrong-kind")
        | wrong-kind |> std/io:print.ln("at-on-array wrong-kind")
    |> std/json:dom.idx(n: r, i: 9)
        | elem _ |> _
        | out-of-bounds |> std/io:print.ln("idx 9 out-of-bounds")
        | wrong-kind |> _
    |> std/json:dom.idx(n: r, i: 3)
        | elem e3 |> std/json:dom.val(n: e3)
            | null |> std/io:print.ln("elem3 null")
            | object _ |> _
            | array _ |> _
            | str _ |> _
            | numstr _ |> _
            | int _ |> _
            | float _ |> _
            | bool _ |> _
        | out-of-bounds |> _
        | wrong-kind |> _
    |> std/json:dom.idx(n: r, i: 1)
        | elem e1 |> std/json:dom.val(n: e1)
            | float f |> std/io:print.ln("elem1 float")
            | object _ |> _
            | array _ |> _
            | str _ |> _
            | numstr _ |> _
            | int _ |> _
            | bool _ |> _
            | null |> _
        | out-of-bounds |> _
        | wrong-kind |> _
    |> std/json:dom.len(n: r)
        | count c |> std/io:print.ln("len={{ c:d }}")
        | wrong-kind |> _
    |> std/json:dom.free(doc)

// at on an object — missing key
std/json:dom.parse(input: "{\"a\":1}")
| malformed m |> std/io:print.ln("BAD3 {{ m:s }}")
| ok doc2 |> std/json:dom.root(doc: doc2): r2
    |> std/json:dom.at(n: r2, key: "missing")
        | found _ |> _
        | not-found |> std/io:print.ln("missing not-found")
        | wrong-kind |> _
    |> std/json:dom.free(doc: doc2)
