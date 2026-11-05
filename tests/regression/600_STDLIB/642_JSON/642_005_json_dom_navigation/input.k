// std/json:dom — the runtime document model: parse arbitrary JSON into a
// traversable tree, `dom.val` for typed descent, `dom.at`/`dom.idx`/
// `dom.each` for navigation, `dom.render` to serialize back out. The
// companion of the comptime `std/json:parse` transform: dom builds the
// tree parse never materializes, for access paths not known at compile
// time. Node borrows die with the document — `dom.free` discharges the
// <open!> obligation, `emit.free` discharges the render's <emitted!>.
import std/io
import std/json

std/json:dom.parse(input: "{\"name\":\"ada\",\"age\":36,\"tags\":[\"x\",\"y\",\"z\"],\"meta\":{\"lang\":\"koru\"}}")
| malformed m |> std/io:print.ln("BAD {{ m:s }}")
| ok doc |> std/json:dom.root(doc): r
    |> std/json:dom.val(n: r)
        | object o |> std/json:dom.each(n: o)
            ! field f |> std/io:print.ln("key {{ f.key:s }}")
            ! item _ |> _
            | done n |> std/io:print.ln("fields={{ n:d }}")
        | array _ |> _
        | str _ |> _
        | numstr _ |> _
        | int _ |> _
        | float _ |> _
        | bool _ |> _
        | null |> _
    |> std/json:dom.at(n: r, key: "tags")
        | found tags |> std/io:print.ln("have tags") |> std/json:dom.each(n: tags)
            ! field _ |> _
            ! item el |> std/json:dom.val(n: el)
                | str s |> std/io:print.ln("tag {{ s:s }}")
                | object _ |> _
                | array _ |> _
                | numstr _ |> _
                | int _ |> _
                | float _ |> _
                | bool _ |> _
                | null |> _
            | done n |> std/io:print.ln("tags={{ n:d }}")
        | not-found |> _
        | wrong-kind |> _
    |> std/json:dom.at(n: r, key: "meta")
        | found meta |> std/json:dom.at(n: meta, key: "lang")
            | found l |> std/json:dom.val(n: l)
                | str s |> std/io:print.ln("lang={{ s:s }}")
                | object _ |> _
                | array _ |> _
                | numstr _ |> _
                | int _ |> _
                | float _ |> _
                | bool _ |> _
                | null |> _
            | not-found |> _
            | wrong-kind |> _
        | not-found |> _
        | wrong-kind |> _
    |> std/json:dom.at(n: r, key: "age")
        | found age |> std/json:dom.val(n: age)
            | int i |> std/io:print.ln("age={{ i:d }}")
            | object _ |> _
            | array _ |> _
            | str _ |> _
            | numstr _ |> _
            | float _ |> _
            | bool _ |> _
            | null |> _
        | not-found |> _
        | wrong-kind |> _
    |> std/json:dom.len(n: r)
        | count l |> std/io:print.ln("len={{ l:d }}")
        | wrong-kind |> _
    |> std/json:dom.render(n: r): out |> std/io:print.ln("{{ out:s }}")
        |> std/json:emit.free(text: out)
    |> std/json:dom.free(doc)
