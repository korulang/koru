// std/yaml edge paths — `! doc` fires once per document in a
// multi-document stream (each handle its own <open!> obligation);
// anchors/aliases refuse through `malformed` (core schema bound —
// expanding a graph into a tree silently would lie); a broken stream
// hands libyaml's problem text + line in the allocated malformed
// message; scalar-keyed maps keep keys as text.
import std/io
import std/json
import std/yaml

// multi-document stream — two ! doc fires
std/yaml:parse(input: "---\nfirst: 1\n---\nsecond: 2\n")
! doc d |> std/json:dom.root(doc: d): r |> std/json:dom.each(n: r)
        ! field f |> std/io:print.ln("doc has {{ f.key:s }}")
        ! item _ |> _
        | done _ |> _
    |> std/json:dom.free(doc: d)
| done n |> std/io:print.ln("docs={{ n:d }}")
| malformed m |> std/io:print.ln("BAD {{ m:s }}") |> std/io:free(content: m)

// alias — refuses per the core-schema bound
std/yaml:parse(input: "a: &x 1\nb: *x\n")
! doc d |> std/json:dom.free(doc: d)
| done _ |> _
| malformed m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)

// broken stream — libyaml's own problem text + line
std/yaml:parse(input: "a: [unclosed\n")
! doc d |> std/json:dom.free(doc: d)
| done _ |> _
| malformed m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
